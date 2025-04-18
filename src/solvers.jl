using LinearAlgebra: qr, I, norm
using LowRankApprox: pqrfact
using IterativeSolvers
using .BayesianLinear
using LinearAlgebra: SVD, svd
using ActiveSetPursuit
using PythonCall
@doc raw"""
`struct QR` : linear least squares solver, using standard QR factorisation; 
this solver computes 
```math 
 θ = \arg\min \| A \theta - y \|^2 + \lambda \| P \theta \|^2
```
Constructor
```julia
ACEfit.QR(; lambda = 0.0, P = nothing)
``` 
where 
* `λ` : regularisation parameter 
* `P` : right-preconditioner / tychonov operator
"""
struct QR
    lambda::Number
    P::Any
end

QR(; lambda = 0.0, P = I) = QR(lambda, P)

function solve(solver::QR, A, y)
    if solver.lambda == 0
        AP = A
        yP = y
    else
        AP = [A; solver.lambda * solver.P]
        yP = [y; zeros(eltype(y), size(A, 2))]
    end
    return Dict{String, Any}("C" => qr(AP) \ yP)
end

@doc raw"""
`struct RRQR` : linear least squares solver, using rank-revealing QR 
factorisation, which can sometimes be more robust / faster than the 
standard regularised QR factorisation. This solver first transforms the 
parameters ``\theta_P = P \theta``, then solves
```math 
 θ = \arg\min \| A P^{-1} \theta_P - y \|^2
```
where the truncation tolerance is given by the `rtol` parameter, and 
finally reverses the transformation. This uses the `pqrfact` of `LowRankApprox.jl`; 
For further details see the documentation of 
[`LowRankApprox.jl`](https://github.com/JuliaMatrices/LowRankApprox.jl#qr-decomposition).

Crucially, note that this algorithm is *not deterministic*; the results can change 
slightly between applications.

Constructor
```julia
ACEfit.RRQR(; rtol = 1e-15, P = I)
``` 
where 
* `rtol` : truncation tolerance
* `P` : right-preconditioner / tychonov operator
"""
struct RRQR
    rtol::Number
    P::Any
end

RRQR(; rtol = 1e-15, P = I) = RRQR(rtol, P)

function solve(solver::RRQR, A, y)
    AP = A / solver.P
    θP = pqrfact(AP, rtol = solver.rtol) \ y
    return Dict{String, Any}("C" => solver.P \ θP)
end

@doc raw"""
LSQR
"""
struct LSQR
    damp::Number
    atol::Number
    conlim::Number
    maxiter::Integer
    verbose::Bool
    P::Any
end

function LSQR(; damp = 5e-3, atol = 1e-6, conlim = 1e8, maxiter = 100000, verbose = false,
              P = nothing)
    LSQR(damp, atol, conlim, maxiter, verbose, P)
end

function solve(solver::LSQR, A, y)
    @warn "Need to apply preconditioner in LSQR."
    println("damp  ", solver.damp)
    println("atol  ", solver.atol)
    println("maxiter  ", solver.maxiter)
    c, ch = lsqr(A, y; damp = solver.damp, atol = solver.atol, conlim = solver.conlim,
                 maxiter = solver.maxiter, verbose = solver.verbose, log = true)
    println(ch)
    println("relative RMS error  ", norm(A * c - y) / norm(y))
    return Dict{String, Any}("C" => c)
end

@doc raw"""
`struct BLR` : Bayesian linear regression

    Refer to bayesianlinear.jl (for now) for kwarg definitions.
"""
struct BLR
    kwargs::Dict{Any,Any}
end

function BLR(; kwargs...)
    return BLR(Dict(kwargs))
end

function solve(solver::BLR, A, y)
    return bayesian_linear_regression(A, y; solver.kwargs...)
end

@doc raw"""
SKLEARN_BRR
"""
struct SKLEARN_BRR
    tol::Number
    max_iter::Integer
end

function SKLEARN_BRR(; tol = 1e-3, max_iter = 300)
    @warn "SKLearn will transition to MLJ in future, please upgrade your script to reflect this."
    SKLEARN_BRR(tol, max_iter)
end

# solve(solver::SKLEARN_BRR, ...) is implemented in ext/

@doc raw"""
SKLEARN_ARD
"""
struct SKLEARN_ARD
    max_iter::Integer
    tol::Number
    threshold_lambda::Number
end

function SKLEARN_ARD(; max_iter = 300, tol = 1e-3, threshold_lambda = 10000)
    @warn "SKLearn will transition to MLJ in future, please upgrade your script to reflect this."
    SKLEARN_ARD(max_iter, tol, threshold_lambda)
end

# solve(solver::SKLEARN_ARD, ...) is implemented in ext/

struct POPSREGRESSION
    max_iter::Integer
    tol::Number
end

function POPSREGRESSION(; max_iter = 300, tol = 1e-3)
    POPSREGRESSION(max_iter, tol)
end

@doc raw"""
`struct TruncatedSVD` : linear least squares solver for approximately solving 
```math 
 θ = \arg\min \| A \theta - y \|^2 
```
- transform  $\tilde\theta  = P \theta$
- perform svd on $A P^{-1}$
- truncate svd at `rtol`, i.e. keep only the components for which $\sigma_i \geq {\rm rtol} \max \sigma_i$
- Compute $\tilde\theta$ from via pseudo-inverse
- Reverse transformation $\theta = P^{-1} \tilde\theta$

Constructor
```julia
ACEfit.TruncatedSVD(; rtol = 1e-9, P = I)
``` 
where 
* `rtol` : relative tolerance
* `P` : right-preconditioner / tychonov operator
"""
struct TruncatedSVD
    rtol::Number
    P::Any
end

TruncatedSVD(; rtol = 1e-9, P = I) = TruncatedSVD(rtol, P)

function trunc_svd(USV::SVD, Y, rtol)
    U, S, V = USV # svd(A)
    Ikeep = findall(x -> x > rtol, S ./ maximum(S))
    U1 = @view U[:, Ikeep]
    S1 = S[Ikeep]
    V1 = @view V[:, Ikeep]
    return V1 * (S1 .\ (U1' * Y))
end

function solve(solver::TruncatedSVD, A, y)
    AP = A / solver.P
    print("Truncted SVD: perform svd ... ")
    USV = svd(AP)
    print("done. truncation ... ")
    θP = trunc_svd(USV, y, solver.rtol)
    println("done.")
    return Dict{String, Any}("C" => solver.P \ θP)
end


# ------------ Truncated SVD with tol specified by validation set ------------ 

function solve_tsvd(At, yt, Av, yv) 
    Ut, Σt, Vt = svd(At); zt = Ut' * yt
    Qv, Rv = qr(Av); zv = Matrix(Qv)' * yv
    @assert issorted(Σt, rev=true)
 
    Rv_Vt = Rv * Vt
 
    θv = zeros(size(Av, 2))
    θv[1] = zt[1] / Σt[1] 
    rv = Rv_Vt[:, 1] * θv[1] - zv 
 
    tsvd_errs = Float64[] 
    push!(tsvd_errs, norm(rv))
 
    for k = 2:length(Σt)
       θv[k] = zt[k] / Σt[k]
       rv += Rv_Vt[:, k] * θv[k]
       push!(tsvd_errs, norm(rv))
    end
 
    imin = argmin(tsvd_errs)
    θv[imin+1:end] .= 0
    return Vt * θv, Σt[imin]
 end


function solve(solver::TruncatedSVD, At, yt, Av, yv)
    # make a function barrier because solver.P is not inferred 
    θ, σ = solve_tsvd(At / solver.P, yt, Av / solver.P, yv)
    return Dict{String, Any}("C" => solver.P \ θ, "σ" => σ)
end
