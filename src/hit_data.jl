# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    read_hit_cal(l200::LegendData, det, runs, e_type::Symbol, expressions)

Read the single-pulse, non-pulser events (`jlqcs` tier) of the `cal` data of detector `det`
for each `(period, run)` in `runs` and return them as one `Table`.

The table holds the `jldsp` columns that `expressions` (PropertyFunction expressions, e.g.
the A/E functions of the PSD config) and the run-level energy calibration function of
`e_type` use, plus `timestamp`, and the column `e_type` with the energy calibrated with the
calibration function of each run (`l200.par.rpars.ecal[period, run][det]`). `e_type` is the
name of the calibrated energy, e.g. `:e_cusp_ctc_cal`, whose calibration function is that of
the energy without the `_cal` suffix. An expression may use the column `e_type`; it is not
read from `jldsp`.
"""
function read_hit_cal(l200::LegendData, det, runs, e_type::Symbol, expressions)
    e_type_uncal = Symbol(first(split(string(e_type), "_cal")))
    cal_funcs = [ljl_propfunc(l200.par.rpars.ecal[period, run][det][e_type_uncal].cal.func) for (period, run) in runs]
    pfs = vcat(cal_funcs, [ljl_propfunc(expr) for expr in expressions])
    dsp_columns = Tuple(setdiff(unique(vcat(:timestamp,
                                            [first(typeof(path).parameters[1]) for pf in pfs
                                             for path in PropertyFunctions.input_property_paths(pf)])), (e_type,)))
    @debug "Reading jldsp columns $(dsp_columns)"
    return fast_flatten([begin
                             @debug "Reading from $period-$run"
                             qc_mask = read_ldata(@pf($is_single_pulse && !$is_pulser), l200, :jlqcs,
                                                  start_filekey(l200, (period, run, :cal)),
                                                  det)
                             dsp = Table(read_ldata(dsp_columns, l200, :jldsp, :cal, period, run, det))[qc_mask]
                             Table(merge(columns(dsp), NamedTuple{(e_type,)}((cal_func.(dsp),))))
                         end
                         for ((period, run), cal_func) in zip(runs, cal_funcs)])
end
