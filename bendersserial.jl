require("extensive")

const clpsubproblem = ClpModel()
clp_set_log_level(clpsubproblem,0)

function setGlobalProbData(d::SMPSData)
    global probdata = d
end

function solveSubproblem(rowlb, rowub)

    Tmat = probdata.Tmat
    ncol1 = probdata.firstStageData.ncol
    nrow2 = probdata.secondStageTemplate.nrow

    clp_chg_row_lower(clpsubproblem,rowlb)
    clp_chg_row_upper(clpsubproblem,rowub)
    clp_initial_solve(clpsubproblem)
    # don't handle infeasible subproblems yet
    @assert clp_is_proven_optimal(clpsubproblem)
    optval = clp_get_obj_value(clpsubproblem)
    duals = clp_dual_row_solution(clpsubproblem)
    
    subgrad = zeros(ncol1)
    for i in 1:nrow2
        status = clp_get_row_status(clpsubproblem,i)
        if (status == 1) # basic
            continue
        end
        for k in 1:ncol1
            subgrad[k] += -duals[i]*Tmat[i,k]
        end
    end

    return optval, subgrad
end



function solveBendersSerial(d::SMPSData, nscen::Integer)

    scenarioData = monteCarloSample(d,1:nscen)

    stage1sol = solveExtensive(d,1)
    
    clpmaster = ClpModel()
    setGlobalProbData(d)
    ncol1 = d.firstStageData.ncol
    nrow1 = d.firstStageData.nrow
    nrow2 = d.secondStageTemplate.nrow
    # add \theta variables for cuts
    thetaidx = [(ncol1+1):(ncol1+nscen)]
    clp_load_problem(clpmaster, d.Amat, d.firstStageData.collb,
        d.firstStageData.colub, d.firstStageData.obj, d.firstStageData.rowlb,
        d.firstStageData.rowub)
    zeromat = SparseMatrixCSC(int32(nrow1),int32(nscen),ones(Int32,nscen+1),Int32[],Float64[])
    clp_add_columns(clpmaster, -1e8*ones(nscen), Inf*ones(nscen),
        (1/nscen)*ones(nscen), zeromat)

    clp_load_problem(clpsubproblem, d.Wmat, d.secondStageTemplate.collb,
        d.secondStageTemplate.colub, d.secondStageTemplate.obj,
        d.secondStageTemplate.rowlb, d.secondStageTemplate.rowub)

    thetasol = -1e8*ones(nscen)

    converged = false
    niter = 0
    mastertime = 0.
    while true
        Tx = d.Tmat*stage1sol
        # solve benders subproblems
        nviolated = 0
        #print("current solution is [")
        #for i in 1:ncol1
        #    print("$(stage1sol[i]),")
        #end
        #println("]")
        for s in 1:nscen
            optval, subgrad = solveSubproblem(scenarioData[s][1]-Tx,scenarioData[s][2]-Tx)
            #println("For scen $s, optval is $optval and model value is $(thetasol[s])")
            if (optval > thetasol[s] + 1e-7)
                nviolated += 1
                #print("adding cut: [")
                # add (0-based) cut to master
                cutvec = Float64[]
                cutcolidx = Int32[]
                for k in 1:ncol1
                 #   print("$(subgrad[k]),")
                    if abs(subgrad[k]) > 1e-10
                        push(cutvec,-subgrad[k])
                        push(cutcolidx,k-1)
                    end
                end
                #println("]")
                push(cutvec,1.)
                push(cutcolidx,ncol1+s-1)
                cutnnz = length(cutvec)
                cutlb = optval-dot(subgrad,stage1sol)

                clp_add_rows(clpmaster, 1, [cutlb], [1e25], Int32[0,cutnnz], cutcolidx, cutvec)
            end

        end

        if nviolated == 0
            break
        end
        println("Generated $nviolated violated cuts")
        # resolve master
        t = time()
        clp_initial_solve(clpmaster)
        mastertime += time() - t
        @assert clp_is_proven_optimal(clpmaster)
        sol = clp_get_col_solution(clpmaster)
        stage1sol = sol[1:ncol1]
        thetasol = sol[(ncol1+1):end]
        niter += 1
    end

    println("Optimal objective is: $(clp_get_obj_value(clpmaster)), $niter iterations")
    println("Time in master: $mastertime sec")

end

