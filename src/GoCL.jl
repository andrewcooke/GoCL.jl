
module GoCL

export fix, @forall, @forall_fold,
       Point, black, empty, white, other,
       Board, point,
       Position, IllegalMove,
       move!

using AutoHashEquals
import Base: ==, print


# todo
# size of spaces?  maybe not important - kindof available in flood fill.
# good scoring (at least for end of game assessment, maybe then fold stuff into
# pre-processing layer.
# graphs, evolution, tournaments etc


# --- utilities


"""this package assumes [x,y] indexing, with x varying fastest and
origin bottom left.  this is not how julia displays matrices (not at
all), so things can be confusing if you use "print" on raw structures.
this function converts for display."""
fix{T}(x::Array{T, 2}) = x'[size(x)[1]:-1:1,:]



# --- macros


"""execute the same code at each point on the board (tries to
guarantee that the julia code is structured similarly to an opencl
kernel)."""
macro forall(i, j, n, block)
    :(for $(esc(i)) in 1:$(esc(n))
          for $(esc(j)) in 1:$(esc(n))
              $(esc(block))
          end
      end)
end

"""as forall, but also include a final reduction (again, easy to
implement in a kernel)."""
macro forall_fold(i, j, n, f, z, r, block)
    :(for $(esc(i)) in 1:$(esc(n))
          for $(esc(j)) in 1:$(esc(n))
              $(esc(block))
          end
      end;
      foldl($(esc(f)), $(esc(z)), $(esc(r))))
end

"""iterate over neigbours - explicit loop (not parallelized) (to
reduce board lookup dx=0 should be grouped)."""
macro forneighbours(x, y, n, xx, yy, block)
    :(for (dx, dy) in ((0, 1), (0, -1), (1, 0), (-1, 0))
          $(esc(xx)), $(esc(yy)) = $(esc(x)) + dx, $(esc(y)) + dy      
          if $(esc(xx)) > 0 && $(esc(xx)) <= $(esc(n)) && $(esc(yy)) > 0 && $(esc(yy)) <= $(esc(n))
              $(esc(block))
          end
      end)
end


# --- data structures


"""a point on the board - empty, or a stone."""
@enum Point empty=0 black=1 white=-1

"""if the point is a stone, give a stone of the other colour.  if
empty, return empty."""
other(t::Point) = t == empty ? empty : (t == black ? white : black)


"""a row of 19 trits fits nicely in 32 bits binary."""
typealias Row UInt32

"""a row of n zeros (signed trits)."""
emptyrow(n) = Row(sum([3^(n-1) for n in 1:n]))

"""a trit-map of the entire board."""
@auto_hash_equals immutable Board{N}
    row::Vector{Row}
    Board() = new(fill(emptyrow(N), N))
    Board(b::Board) = new(copy(b.row))
end


"""identify points common to a group and provide basic stats."""
@auto_hash_equals immutable Groups{N}
    index::Array{UInt8, 2}
    # do we need to care about overflow here?
    size::Array{UInt8, 1}
    lives::Array{UInt8, 1}
    Groups() = new(zeros(UInt8, N, N), zeros(UInt8, 255), zeros(UInt8, 255))
    Groups(g::Groups{N}) = new(copy(g.index), copy(g.size), copy(g.lives))
end


"""a map of cartesian signed distances to the nearest non-empty point,
where the sign indicates whether the nearest point is black or white
(via the Point enumeration).

distances are offset by 1, so a value of +/-1 indicates that the point
contains a stone.  a value of zero is used initially (replaced on
first move by flood_to_point!) and as a marker for deleted groups
(replaced by flood_dead_group!).

this contains almost all the information about the state of play (the
+/-1 values duplicate Board).  it may be used as input to a neural
net."""
@auto_hash_equals immutable Flood{N}
    distance::Array{Int8, 2}
    Flood() = new(zeros(Int8, N, N))
    Flood(f::Flood{N}) = new(copy(f.distance))
end

@auto_hash_equals immutable Space{N}
    border::Array{Int8, 2}
    index::Array{UInt8, 2}
    Space() = new(zeros(Int8, N, N), zeros(UInt8, N, N))
    Space(s::Space{N}) = new(copy(s.border), copy(s.index))
end

"""a single position (implicitly, in a search tree).  combines Board,
Groups and Flood."""
@auto_hash_equals immutable Position{N}
    board::Board{N}
    groups::Groups{N}
    flood::Flood{N}
    space::Space{N}
    Position() = new(Board{N}(), Groups{N}(), Flood{N}(), Space{N}())
    Position(p::Position) =
        new(Board{N}(p.board), Groups{N}(p.groups), Flood{N}(p.flood), Space{N}(p.space))
end

Position() = Position{19}()


# --- points


"""extract the point at a given (x, y)."""
point(r::Row, x) = Point(mod(div(r, 3^(x-1)), 3)-1)

"""extract the point at a given (x, y)."""
point(b::Board, x, y) = point(b.row[y], x)

"""extract the point at a given (x, y)."""
point(p::Position, x, y) = point(p.board, x, y)


# --- display


"""the location of board markers (dots)."""
markers(n) = Set([Integer(floor(n/4)), (n+1)/2, n+1-Integer(floor(n/4))])

function fmtpoint(r::Row, y, n)
    m = markers(n)
    fmt(x) = (y in m && x in m ? "O+X" : "O.X")[2+Int(point(r, x))]
    # extra space aligns with other components that use 2 characters
    # per point
    string(" ", join(map(fmt, 1:n), " "))
end
fmtpoint{N}(b::Board{N}) = map(y -> fmtpoint(b.row[y], y, N), N:-1:1)

print(io::IO, b::Board) = print(io, join(fmtpoint(b), "\n"))

function fmtindex(index::Array{UInt8, 2}, y, n)
    m = markers(n)
    function fmt(x)
        if index[x, y] > 0
            @sprintf("%02X", index[x, y])
        elseif y in m && x in m
            "__"
        else
            "  "
        end
    end
    join(map(fmt, 1:n))
end
fmtindex{N}(g::Groups{N}) = map(y -> fmtindex(g.index, y, N), N:-1:1)

stats_per_row = 4
function fmtstats(g::Groups, row)
    function fmt(col)
        i = col + (row-1) * stats_per_row
        @sprintf("%02x:%2d/%2d", i, g.lives[i], g.size[i])
    end
    join(map(fmt, 1:stats_per_row), ", ")
end
fmtstats{N}(g::Groups{N}) = map(r -> fmtstats(g, r), 1:N)

function print(io::IO, g::Groups)
    print(io, join(fmtindex(g), "\n"))
    print(io, "\n")
    print(io, join(fmtstats(g), "\n"))
end

function fmtdistance{N}(f::Flood{N}, y)
    function fmt(x)
        d = f.distance[x, y]
        if abs(d) < 10
            @sprintf("%2d", d)
        elseif d > 0
            string(" ", Char(Int('a') + d - 10))
        else
            string(" ", Char(Int('A') - d - 10))
        end
    end
    join(map(fmt, 1:1N))
end
fmtdistance{N}(f::Flood{N}) = map(y -> fmtdistance(f, y), N:-1:1)

print(io::IO, f::Flood) = print(io, join(fmtdistance(f), "\n"))

fmtindex{N}(s::Space{N}) = map(y -> fmtindex(s.index, y, N), N:-1:1)

function fmtborder{N}(s::Space{N}, y)
    fmt(x) = " XO."[s.border[x, y]+1]
    string(" ", join(map(fmt, 1:N), " "))
end
fmtborder{N}(s::Space{N}) = map(y -> fmtborder(s, y), N:-1:1)

function print(io::IO, s::Space)
    print(io, join(fmtborder(s), "\n"))
    print(io, "\n")
    print(io, join(fmtindex(s), "\n"))
end

function print(io::IO, p::Position)
    print(io, 
          join(map(x -> join(x, "  "), 
                   zip(fmtpoint(p.board), 
                       fmtindex(p.groups))), "\n"))
    print(io, "\n")
    print(io, "\n")
    print(io,
          join(map(x -> join(x, "  "), 
                   zip(fmtdistance(p.flood), 
                       fmtstats(p.groups))), "\n"))
    print(io, "\n")
    print(io, "\n")
    print(io,
          join(map(x -> join(x, "  "), 
                   zip(fmtborder(p.space), 
                       fmtindex(p.space))), "\n"))
end


# --- update state on move


function k_lowest_unused(k, a::Array{UInt8, 2}, n)
    available = collect(UInt8, 1:255)
    result = zeros(UInt8, k)
    function extract(result, value)
        if value > 0
            for i in 1:k
                if result[i] == 0
                    result[i] = value
                    break
                end
            end
        end
        result
    end
    @forall_fold i j n extract result available begin
        if a[i, j] > 0
            available[a[i, j]] = 0
        end
    end
end

"""merge the group at (x,y) with newgroup."""
function merge_group{N}(g::Groups{N}, newgroup, x, y)
    oldgroup = g.index[x, y]
    if newgroup != oldgroup
        g.size[newgroup], g.size[oldgroup] = g.size[newgroup] + g.size[oldgroup], 0
        @forall i j N begin
            if g.index[i, j] == oldgroup
                g.index[i, j] = newgroup
            end
        end
    end
end

"""check whether the group at (x, y) is dead.  if so, remove it from
Groups.index, sets Flood.distance to zero (these are later replaced in
flood_dead_group!) and Space.index to the next available value
(patched up in fix_space!)."""
function check_and_delete_group!{N}(p::Position{N}, x, y)
    alive = zeros(Bool, N, N)
    # the group we want to check
    group = p.groups.index[x, y]
    if ! @forall_fold i j N (x,y) -> any([x,y]) false alive begin 
        if p.groups.index[i, j] == group
            @forneighbours x y N xx yy begin
                # if a neighbour is empty, return that via the fold
                if point(p.board, xx, yy) == empty
                    alive[i, j] = true
                end
            end
        end
    end
        # if not alive
        space = k_lowest_unused(1, p.space.index, N)[1]
        p.groups.size[group] = 0
        @forall i j N begin
            if p.groups.index[i, j] == group
                # remove stone
                move!(p.board, empty, i, j)
                # TOOO - increment prisoner count
                # erase group index
                p.groups.index[i, j] = 0
                p.space.index[i, j] = space
                # set flood to special value (see flood_dead_group!)
                p.flood.distance[i, j] = 0
            end
        end
    end
end

"""replace Flood.distance values that have been zeroed."""
function flood_dead_group!{N}(f::Flood{N}, b::Board{N}, t::Point)
    while ! @forall_fold i j N (a,b) -> (a || b!=0) false f.distance begin
        if f.distance[i, j] == 0
           # find closest neighbour
           mind = 256
           @forneighbours i j N ii jj begin
               d = f.distance[ii, jj]
               if d != 0
                   mind = min(mind, abs(d))
               end
           end
           # if we have a neighbour, add one to that
           if mind < 256
               f.distance[i, j] = Int(t) * (mind+1)
           end
       end
    end
        # while zero distances exist (repeat above)
    end
end

"""update Flood.distance when a stone is played.  this is done by
moving from each point towards the new stone.  if the path reaches the
stone without meeting any other, and the distance is less than the
current value, then it is updated.  i am not completely sure this is
exact, but it appears to work ok."""
function flood_to_point!{N}(f::Flood{N}, b::Board{N}, t::Point, x, y)
    @forall i j N begin
        if point(b, i, j) == empty
            ii, jj, d = i, j, 1
            while true
                di, dj, d = x-ii, y-jj, d+1
                if abs(di) >= abs(dj)
                    ii = ii + sign(di)
                else
                    jj = jj + sign(dj)
                end
                if point(b, ii, jj) != empty
                    break
                end
            end
            if ii == x && jj == y
                prev = f.distance[i, j]
                if prev == 0 || abs(d) < abs(prev)
                    f.distance[i, j] = d * Int(t)
                end
            end
        end
    end
end

"""re-calculate (from scratch) the number of lives associated with
each group."""
function calculate_lives!{N}(g::Groups{N})
    # the general idea here is that for each space, we see whether it
    # contributes a life to any group (by lookng at neighbouting
    # groups).  then we add those lives up.  this avoids "double
    # counting" spaces that touch more than one stone.
    for k in 1:255
        g.lives[k] = 0
    end
    # local vars
    temp = zeros(UInt8, N, N, 4)   # neighbouring groups
    n = zeros(UInt8, N, N)         # number of neighbouring groups (<=4)
    @forall i j N begin
        # for spaces
        if g.index[i, j] == 0
            @forneighbours i j N ii jj begin
                group = g.index[ii, jj]
                # if group is not already known
                if group != 0 && !any([group == temp[i, j, k] for k in 1:n[i, j]])
                    n[i, j] = n[i, j] + 1
                    temp[i, j, n[i, j]] = group
                end
            end
            # thread group mem with memory guard
            for k in 1:n[i, j]
                g.lives[temp[i, j, k]] = g.lives[temp[i, j, k]] + 1
            end
        end
    end
end

"""the Space.border array uses this mask to indicate the border
colour(s).  it is chosen so that updating adjacent values using or
works ok, but needs translating at the net level."""
function border_mask(t::Point)
    if t == empty
        return 0
    elseif t == black
        return 1
    else
        return 2
    end
end

"""iteratively update space wherever the border is (initially) zero
until the index and border are consistent acrosss the group (lowest
index, combined border)."""
function fix_space!{N}(s::Space{N}, b::Board{N})
    
    my_active = zeros(Bool, N, N)
    my_nsew = zeros(UInt8, N, N)   # bitmask of stones (to ignore in round 2)
    my_index = zeros(UInt8, N, N)
    my_border = zeros(UInt8, N, N)
    my_k = zeros(UInt8, N, N)

    # first round, set border from stones
    @forall i j N begin
        my_active[i, j] = s.border[i, j] == 0 && point(b, i, j) == empty
        if my_active[i, j]
            my_index[i, j] = s.index[i, j]
            @forneighbours i j N ii jj begin
                t = point(b, ii, jj)
                if t != empty
                    my_border[i, j] = my_border[i, j] | border_mask(t)
                    my_nsew[i, j] = my_nsew[i, j] | 2^my_k[i, j]
                end
                my_k[i, j] = my_k[i, j] + 1
            end
            s.border[i, j] = my_border[i, j]
        end
    end
    
    # second round - update until consistent
    our_changed = true
    while our_changed
        our_changed = false
        my_k = zeros(UInt8, N, N)
        
        @forall i j N begin
            my_changed = zeros(Bool, N, N)
            if my_active[i, j]
                @forneighbours i j N ii jj begin
                    if my_nsew[i, j] & 2^my_k[i, j] == 0
                        index = s.index[ii, jj]
                        if index != my_index[i, j] && index > 0 && (my_index[i, j] == 0 || index < my_index[i, j])
                            my_changed[i, j] = true
                            my_index[i, j] = index
                        end
                        border = s.border[ii, jj]
                        if !(border == 0 || border & my_border[i, j] == border)
                            my_changed[i, j] = true
                            my_border[i, j] = my_border[i, j] | border
                        end
                    end
                    my_k[i, j] = my_k[i, j] + 1
                end
                if my_changed[i, j]
                    s.index[i, j] = my_index[i, j]
                    s.border[i, j] = my_border[i, j]
                    our_changed = true
                end
            end
        end
    end

end

"""add space indices around a new move.  these are then resolved by
fix_space!()."""
function index_new_space!{N}(s::Space{N}, b::Board{N}, x, y)
    available = k_lowest_unused(4, s.index, N)
    k = 1
    @forneighbours x y N xx yy begin
        if point(b, xx, yy) == empty
            s.index[xx, yy] = available[k]
            k = k+1
        end
    end
end

type IllegalMove <: Exception end

function assert_empty(p, x, y)
    if point(p, x, y) != empty
        throw(IllegalMove())
    end
end

function assert_alive(p, x, y)
    if p.groups.lives[p.groups.index[x, y]] == 0
        throw(IllegalMove())
    end
end

"""update the row to include the given Point."""
function move(row::Row, t::Point, x)
    k = 3^(x-1)
    l, r = divrem(row, k)
    l = 3 * div(l, 3) + Row(Int(t)+1)
    l * k + r
end

"""update the board to include the given point."""
move!(b::Board, t::Point, x, y) = b.row[y] = move(b.row[y], t, x)

"""update Flood.distance to include the given point (only - full
flood update requires flood_dead_group! and flood_to_point!)."""
move!(f::Flood, t::Point, x, y) = f.distance[x, y] = Int8(t)

function move!{N}(s::Space{N}, x, y)
    index = s.index[x, y]
    @forall i j N begin
        if s.index[i, j] == index
            s.index[i, j] = 0
            s.border[i, j] = 0
        end
    end
end

"""update the position, given a new point.  this includes all
processing."""
function move!{N}(p::Position{N}, t::Point, x, y)
    assert_empty(p, x, y)
    move!(p.board, t, x, y)
    move!(p.flood, t, x, y)
    move!(p.space, x, y)
    flood_to_point!(p.flood, p.board, t, x, y)
    index_new_space!(p.space, p.board, x, y)
    newgroup = k_lowest_unused(1, p.groups.index, N)[1]
    p.groups.index[x, y] = newgroup
    p.groups.size[newgroup] = 1
    @forneighbours x y N xx yy begin
        tt = point(p.board, xx, yy)
        if tt == t
            merge_group(p.groups, newgroup, xx, yy)
        elseif tt == other(t)
            check_and_delete_group!(p, xx, yy)
        end
    end
    flood_dead_group!(p.flood, p.board, t)
    calculate_lives!(p.groups)
    fix_space!(p.space, p.board)
    assert_alive(p, x, y)
    p   # support call with new instance
end


# --- convolution


# http://developer.amd.com/resources/documentation-articles/articles-whitepapers/tiled-convolution-fast-image-filtering/
# has a detailed argument about why and how to do this better on a
# real gpu (although this case is simpler as it fits in a single tile)

"""convolve a 3x3 cross-shaped kernel."""
function convolve(input, border, kernel, output, n)
    @forall i j n begin
        a = 0
        # cannot use forneighbours because we need di, dj
        for (di, dj) in ((0, 1), (0, -1), (1, 0), (-1, 0))
            ii, jj = i+di, j+dj
            if ii > 0 && ii <= n && jj > 0 && jj <= n
                a = a + kernel[di+2, dj+2] * input[ii, jj]
            else
                a = a + kernel[di+2, dj+2] * border
            end
            output[i, j] = a
        end
    end
end

function blank!{N}(data, p::Position{N})
    @forall i j N begin
        if point(p, i, j) != empty
            data[i, j] = 0
        end
    end
end


# --- scoring


# grow boundaries inwards
# expand conflicting values outwards
# reduce to find score


end
