module JSExpr

using JSON, MacroTools, WebIO
export JSString, @js, @js_str

import WebIO: JSString

macro js(expr)
    :(JSString(string($(jsstring(expr)...))))
end

# Expressions

jsexpr(x::JSString) = x.s
jsexpr(x::Symbol) = (x==:nothing ? "null" : string(x))
jsexpr(x) = JSON.json(x)
jsexpr(x::QuoteNode) = x.value isa Symbol ? jsexpr(string(x.value)) : jsexpr(x.value)
jsexpr(x::LineNumberNode) = nothing

include("util.jl")

function jsexpr_joined(xs, delim=",")
    isempty(xs) && return ""
    F(intersperse(jsexpr.(xs), delim))
end

jsstring(x) = _simplify(_flatten(jsexpr(x)))

function block_expr(args, delim="; ")
    #print(io, "{")
    jsexpr_joined(rmlines(args), delim)
    #print(io, "}")
end

function call_expr(f, args...)
    if f in [:(=), :+, :-, :*, :/, :%, :(==), :(===),
             :(!=), :(!==), :(>), :(<), :(<=), :(>=)]
        return F(["(", jsexpr_joined(args, string(f)), ")"])
    end
    F([jsexpr(f), "(", F([jsexpr_joined(args)]), ")"])
end

function obs_get_expr(x)
    # empty [], special case to get value from an Observable
    F(["WebIO.getval(", jsexpr(x), ")"])
end

function obs_set_expr(x, val)
    # empty [], special case to get value from an Observable
    F(["WebIO.setval(", jsexpr_joined([:(jsexpr_observable(x)), val]), ")"])
end

function jsexpr(o::WebIO.Observable)
    if !haskey(observ_id_dict, o)
        error("No scope associated with observer being interpolated")
    end
    _scope, name = observ_id_dict[o]
    _scope.value === nothing && error("Scope of the observable doesn't exist anymore.")
    scope = _scope.value

    obsobj = Dict("type" => "observable",
                  "scope" => scope.id,
                  "name" => name,
                  "id" => obsid(o))

    jsexpr(obsobj)
end

function ref_expr(x, args...)
    F([jsexpr(x), "[", jsexpr_joined(args), "]"])
end

function func_expr(args, body)
    parts = []
    named = isexpr(args, :call)
    named || push!(parts, "(")
    push!(parts, "function ")
    if named
        push!(parts, string(args.args[1]))
        args.args = args.args[2:end]
    end
    push!(parts, "(")
    isexpr(args, Symbol) ? push!(parts, string(args)) : push!(parts, jsexpr_joined(args.args, ","))
    push!(parts, "){")
    push!(parts, jsexpr(insert_return(body)))
    push!(parts, "}")
    named || push!(parts, ")")
    F(parts)
end

function insert_return(ex)
    if isa(ex, Symbol) || !isexpr(ex, :block)
        Expr(:return, ex)
    else
        isexpr(ex.args[end], :return) && return ex
        ex1 = copy(ex)
        ex1.args[end] = insert_return(ex.args[end])
        ex1
    end
end


function dict_expr(xs)
    parts = []
    xs = map(xs) do x
        if x.head == :(=) || x.head == :kw
            push!(parts, F([jsexpr(x.args[1]), ":", jsexpr(x.args[2])]))
        elseif x.head == :call && x.args[1] == :(=>)
            push!(parts, F([jsexpr(x.args[2]), ":", jsexpr(x.args[3])]))
        else
            error("Invalid pair separator in dict expression")
        end
    end
    F(["{", F(intersperse(parts, ",")), "}"])
end

function vect_expr(xs)
    F(["[", F(intersperse([jsexpr(x) for x in xs], ",")), "]"])
end

function if_block(ex)

    if isexpr(ex, :block)
        if any(x -> isexpr(x, :macrocall) && x.args[1] == Symbol("@var"), ex.args)
            error("@js expression error: @var inside an if statement is not supported")
        end
        print(io, "(")
        block_expr(io, rmlines(ex).args, ", ")
        print(io, ")")
    else
        jsexpr(io, ex)
    end
end

function if_expr(xs)
    if length(xs) >= 2    # we have an if
        jsexpr(xs[1])
        print(" ? ")
        if_block(io, xs[2])
    end

    if length(xs) == 3    # Also have an else
        print(io, " : ")
        if_block(io, xs[3])
    else
        print(io, " : undefined")
    end
end

function for_expr(io, i, start, to, body, step = 1)
    print(io, "for(var $i = $start; $i <= $to; $i = $i + $step){")
    block_expr(io, body)
    print(io, "}")
end

function jsexpr(x::Expr)
    isexpr(x, :block) && return block_expr(rmlines(x).args)
    x = rmlines(x)
    @match x begin
        Expr(:macrocall, :@new, :_) => (F(["new ", jsexpr(x.args[2])]))
        Expr(:macrocall, :@var :_) => (F(["var ", jsexpr(x.args[2])]))
        d(xs__) => dict_expr(xs)
        Dict(xs__) => dict_expr(xs)
        $(Expr(:comparison, :_, :(==), :_)) => jsexpr_joined([x.args[1], x.args[3]], "==")    # 0.4

        # must include this particular `:call` expr before the catchall below
        $(Expr(:call, :(==), :_, :_)) => jsexpr_joined([x.args[2], x.args[3]], "==")    # 0.5+
        f_(xs__) => call_expr(f, xs...)
        (a_ -> b_) => func_expr(a, b)
        a_.b_ | a_.(b_) => jsexpr_joined([a, b], ".")
        (a_[] = val_) => obs_set_expr(a, val)
        (a_ = b_) => jsexpr_joined([a, b], "=")
        (a_ += b_) => jsexpr_joined([a, b], "+=")
        (a_ && b_) => jsexpr_joined([a, b], "&&")
        (a_ || b_) => jsexpr_joined([a, b], "||")
        $(Expr(:if, :__)) => if_expr(x.args)
        $(Expr(:function, :__)) => func_expr(x.args...)
        a_[] => obs_get_expr(a)
        a_[i__] => ref_expr(a, i...)
        [xs__] => vect_expr(xs)
        (@m_ xs__) => jsexpr(macroexpand(WebIO, x))
        (for i_ = start_ : to_
            body__
        end) => for_expr(i, start, to, body)
        (for i_ = start_ : step_ : to_
            body__
        end) => for_expr(i, start, to, body, step)
        (return a__) => (F(["return ", !isempty(a) && a[1] !== nothing ? jsexpr(a...) : ""]))
        $(Expr(:quote, :_)) => jsexpr(QuoteNode(x.args[1]))
        $(Expr(:$, :_)) => :(jsexpr($(esc(x.args[1])))) # the expr gets kept around till eval
        _ => error("JSExpr: Unsupported `$(x.head)` expression, $x")
    end
end

macro new(x) esc(Expr(:new, x)) end
macro var(x) esc(Expr(:var, x)) end

end # module