
function play(a::Vector{UInt8}, b::Vector{UInt8}, board_size, max_moves, seed, display)
    passed, t, h = 0, black, [Position{board_size}()]
    rng = MersenneTwister(seed)
    while passed < 2 && h[end].score.moves < max_moves
        played = false
        for m in moves(a, h, t, rng)
            p = Position(h[end])
            move!(p, t, m...)
            if length(filter(x -> x.board == p.board, h)) > 0
                println("repeated position")
            else
                push!(h, p)
                display(p, m...)
                played = true
                break
            end
        end
        if played
            passed = 0
        else
            passed += 1
        end
        a, b, t = b, a, other(t)
    end
    h[end]
end

null_display(p, x, y) = nothing

function board_display(p, x, y)
    t = point(p, x, y)
    @printf("\n\n%d (%d): %s at (%d,%d)\n", p.score.moves, p.score.total, t == black ? "black" : "white", x, y)
    println(join(fmtpoint(p.board), "\n"))
end


# for replay, pick a game from the log.  perhaps
# 1000/1000   6/20   ceaa93b88f34d14f:1   bt fb9b4e8b26cd7702:3    9 sc   81 mv   4 sp  70 st
# and calculate the seed.  in this case (1000-1)*20+6
# the read in the population and replay:
# > d = undump("evol-1.dump");
# > replay_direct(d["ceaa93b88f34d14f"], d["fb9b4e8b26cd7702"], 9, 81, 20*999+6)
# note that the higher ranked net plays first (as black), so if the result is a surprise
# (with a !) then the order of the nets must be reversed from the log.

function replay_direct(a::Vector{UInt8}, b::Vector{UInt8}, board_size, max_moves, seed)
    p = play(a, b, board_size, max_moves, seed, board_display)
    println("\n\nfinal position:")
    println(p)
    p
end

function replay_direct(d::Dict{AbstractString, Vector{UInt8}}, line::AbstractString; board_size=19, max_moves=1000)
# 50/10000  10/25 ! 8414ac2df622accd:38  bt c340be963d5fc19f:5   14 sc  100 mv   5 sp  67 st
# 50/10000  11/25   c340be963d5fc19f:6   bt 6b34dd72635a19e6:19   2 sc   45 mv   6 sp  45 st   
    p = r"^\s*(?P<i>\d+)/(?P<n>\d+)\s+(?P<j>\d+)/(?P<m>\d+) (?P<surprise>(?:!| )) (?P<a>[a-f0-9]+):\d+\s+(?:bt|dr)\s+(?P<b>[a-f0-9]+):\d+.*$"
    m = match(p, line)
    println(m.captures)
    i, n, j, m, surprise, a, b = m.captures
    if surprise == "!"
        a, b = b, a
    end
    seed = (parse(Int, i)-1) * parse(Int, m) + parse(Int, j)
    println("$a v $b (seed $(seed))")
    replay_direct(d[a], d[b], board_size, max_moves, seed)
end
