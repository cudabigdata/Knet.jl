"""
_knet(x) is a compiler that takes the expressions generated by a
@knet function and outputs a list of machine instructions of the form:
```
(Op, in1, in2, ..., out)
```
where Op is a primitive operator, in1, in2, ..., out are symbols
representing input and output registers.

The whole compiler is 7 lines long!

Example:

(1) The user defines a @knet function:
```
@knet function wb(x; o...)
    y = wdot(x; o...)
    z = bias(y; o...)
end
```

(2) The @knet macro turns this into a Julia function which takes
input/output symbols and generates an expression sequence using these
symbols.  The locals are replaced by gensyms:

```
function wb(x::Symbol, z::Symbol; o...)
    @gensym y
    quote
        \$y = wdot(\$x; \$o...)
        \$z = bias(\$y; \$o...)
    end
end
```

(3) The user calls a Net constructor, e.g. FNN(wb; out=100).  The net
constructor (or recursively the compiler) runs the Julia function `wb`
to get:

```
julia> prog = wb(:a,:b; out=100)
quote
    ##y#8260 = wdot(a; Any[(:out,100)]...)
    b = bias(##y#8260; Any[(:out,100)]...)
end
```

(4) This gets passed to the _knet compiler to get:
```
julia> _knet(prog)
 (Par((100,0),Gaussian(0,0.01),...),symbol("##w#8267"))
 (Dot(),symbol("##w#8267"),:a,symbol("##y#8262"))
 (Par((0,),Constant(0),...),symbol("##b#8270"))
 (Add(),symbol("##b#8270"),symbol("##y#8262"),:b)
```

(5) The Net constructor adds input expressions and replaces symbols with Ints to get:
```
net.op = [ Input(), Par((100,0),...), Dot(), Par((0,),...), Add() ]
net.inputs = [ [], [], [2,1], [], [4,3] ]
```
"""
_knet(x::Expr)=(x.head == :block ? _knet_bloc(x.args) : x.head == :(=) ? _knet_assn(x.args...) : error())
_knet_bloc(x::Array)=mapreduce(_knet, append!, x)
_knet_assn(s::Symbol, x::Expr)=(x.head == :call ? _knet_call(x.args...,s) : error())
_knet_call(f, p::Expr, o...)=(p.head == :parameters ? _knet(eval(current_module(), Expr(:call, f, p, map(QuoteNode, o)...))) : error())
_knet_call(f, o...)=_knet(eval(current_module(),Expr(:call,f,map(QuoteNode, o)...)))
_knet(x::Tuple)=(isa(x[1],Op) ? Any[x] : error())
_knet(::LineNumberNode)=Any[]


"""
@knet macro -- This is what the user types:
```
@knet function wdot(x; out=0, winit=Gaussian(0,.01), o...)
    w = par(out,0; init=winit, o...)
    y = dot(w, x)
end
```
This is what the @knet macro turns it into:
```
function wdot(x::Symbol, y::Symbol; out=0, winit=Gaussian(0,.01), o...)
    @gensym w
    quote
        \$w = par(\$out,0; init=\$winit, \$o...)
        \$y = dot(\$w, \$x)
    end
end
```
"""
macro knet(f)
    @assert f.head == :function
    @assert length(f.args) == 2
    @assert f.args[1].head == :call
    @assert f.args[2].head == :block
    name = f.args[1].args[1]
    args = f.args[1].args[2:end]
    pars = _knet_pars(f)
    vars = _knet_vars(f)
    @assert !isempty(vars)
    head = Expr(:call, name, map(_knet_sym, [args; vars[end]])...)
    m = Expr(:macrocall, symbol("@gensym"), vars[1:end-1]...)
    q = Expr(:quote, _knet_esc(f.args[2], vcat(pars, vars)))
    body = Expr(:block, m, q)
    newf = Expr(:function, head, body)
    # dump(STDOUT,newf,100)
    esc(newf)
    # 0
end

function _knet_esc(x::Expr,v::Array)
    if x.head == :line
        x
    elseif x.head == :kw
        Expr(x.head, x.args[1], map(a->_knet_esc(a,v), x.args[2:end])...)
    else
        Expr(x.head, map(a->_knet_esc(a,v), x.args)...)
    end
end

# TODO: add checks when s is not an element of v
_knet_esc(s::Symbol,v::Array)=(in(s,v) ? Expr(:$, s) : s)
_knet_esc(x,v::Array)=x

_knet_sym(s::Symbol)=Expr(:(::), s, :Symbol)
_knet_sym(x)=x

function _knet_pars(f::Expr)
    a = f.args[1].args[2:end]
    all(x->isa(x,Symbol), a) && return a
    @assert isa(a[1],Expr) && a[1].head == :parameters && all(x->isa(x,Symbol), a[2:end])
    vcat(a[2:end], map(kw->kw.args[1], a[1].args))
end

function _knet_vars(f::Expr)
    vars = Any[]
    for a in f.args[2].args
        a.head == :line && continue
        @assert a.head == :(=)
        push!(vars, a.args[1])
    end
    return vars
end
