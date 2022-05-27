using Distributed, DistributedArrays
using LinearAlgebra
using ACEbase: ACEBasis
using JuLIP
using ExtXYZ

function llsq!(model, data::AbstractVector, Vref, par = :serial; solver = QR())
   basis = get_basis(model) # should return an ACEBasis 
   IP, errors = llsq(basis, data, Vref, par; solver = solver)
   #set_params!(model, θ)
   return IP, errors
end

function llsq(basis, data::AbstractVector, Vref, par = :serial; solver = QR())

   if par == :serial
      _iterate = siterate
      A, y, w = asm_llsq(basis, data, _iterate)
      c = solve_llsq(solver, A, y)
      config_errors = error_llsq(data, (A*c)./w, y./w)
      # wcw, this is the old way, should revisit
      IP = JuLIP.MLIPs.combine(basis, c)
      if Vref != nothing
         IP = JuLIP.MLIPs.SumIP(Vref, IP)
      end
      return IP, config_errors
   #elseif par == :mt
   #   _iterate = titerate
   #   A, y = asm_llsq(basis, data, _iterate)
   #elseif par == :dist
   #   _iterate = siterate
   #   A, y, w = asm_llsq_dist(basis, data, _iterate)
   else 
      error("unknown assembly type")
   end
end

function asm_llsq(basis, data, _iterate)

   _, Nobs = get_lsq_indices(data)

   println("Creating design matrix with size (", Nobs, ", ", length(basis), ")")
   A = zeros(Nobs, length(basis))
   Y = zeros(Nobs)
   W = zeros(Nobs)
   
   # inner assembly (this knows about A and Y)
   idx = 1
   # TODO: i0 is not used anymore, should revisit
   function asm_lsq_inner(i0, dat)
      for o in observations(dat)
         # TODO: this isn't type stable; for very cheap models, this inner 
         #       loop could be a bottleneck, can it be fixed? 
         oB = basis_obs(typeof(o), basis, dat.config)
         y = vec_obs(o)
         w = get_weight(o)
         # TODO: make this an input parameter eventually
         if hasproperty(o, :E) || hasproperty(o, :V)
            w = w ./ sqrt(length(dat.config))
         end
         inds = idx:idx+length(y)-1
         Y[inds] .= w.*y[:]
         W[inds] .= w.*ones(length(y))
         for ib = 1:length(basis) 
            ovec = vec_obs(oB[ib])
            A[inds, ib] .= w.*ovec[:]
         end
         idx += length(y)
      end
      return nothing 
   end

   _iterate(asm_lsq_inner, data)


   return A, Y, W
end

function assemble_dist!(A, Y, W, data, basis)

   row = 1
   localrows = localindices(Y)[1]
   function asm_lsq_inner(dat)
      for o in observations(dat)
         y = vec_obs(o)
         if row>localrows[end] || (row-1+length(y))<localrows[1]
            row += length(y)    # increment and move on, because
            continue            # there is no local work to do
         end
         oB = basis_obs(typeof(o), basis, dat.config)
         w = get_weight(o)
         # TODO: make this an input parameter eventually
         if hasproperty(o, :E) || hasproperty(o, :V)
            w = w ./ sqrt(length(dat.config))
         end
         # fill rows of Y and A
         for i in 1:length(y)
            if row>=localrows[1] && row<=localrows[end]
               localpart(Y)[row-localrows[1]+1] = w*y[i]
               localpart(W)[row-localrows[1]+1] = w
               for ib = 1:length(basis)
                  localpart(A)[row-localrows[1]+1, ib] = w*vec_obs(oB[ib])[i]
               end
            end
            row += 1
         end
      end
      return nothing
   end

   for dat in data
      asm_lsq_inner(dat)
   end

   return nothing
end

function assemble_dist_new!(A, Y, W, params, basis)

    row = 1
    localrows = localindices(Y)[1]
    function asm_lsq_inner(dat)
       for o in observations(dat)
          y = vec_obs(o)
          if row>localrows[end] || (row-1+length(y))<localrows[1]
             row += length(y)    # increment and move on, because
             continue            # there is no local work to do
          end
          oB = basis_obs(typeof(o), basis, dat.config)
          w = get_weight(o)
          # TODO: make this an input parameter eventually
          if hasproperty(o, :E) || hasproperty(o, :V)
             w = w ./ sqrt(length(dat.config))
          end
          # fill rows of Y and A
          for i in 1:length(y)
             if row>=localrows[1] && row<=localrows[end]
                localpart(Y)[row-localrows[1]+1] = w*y[i]
                localpart(W)[row-localrows[1]+1] = w
                for ib = 1:length(basis)
                   localpart(A)[row-localrows[1]+1, ib] = w*vec_obs(oB[ib])[i]
                end
             end
             row += 1
          end
       end
       return nothing
    end

    for dict in ExtXYZ.iread_frames(params["data"]["fname"])
        atoms = JuLIP._extxyz_dict_to_atoms(dict)
        v_ref = OneBody(convert(Dict{String,Any},params["e0"]))
        energy_key = params["data"]["energy_key"]
        force_key = params["data"]["force_key"]
        virial_key = params["data"]["virial_key"]
        weights = params["weights"]
        data = _atoms_to_data(atoms, v_ref, weights, energy_key, force_key, virial_key)
        asm_lsq_inner(data)
    end
 
    return nothing
end
