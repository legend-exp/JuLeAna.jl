# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    read_hit_cal(l200::LegendData, det, runs, e_types::AbstractVector{Symbol}, expressions)

Read the single-pulse, non-pulser events (`jlqcs` tier) of the `cal` data of detector `det`
for each `(period, run)` in `runs` and return them as one `Table`.

The table holds the `jldsp` columns that `expressions` (PropertyFunction expressions, e.g.
the A/E functions of the PSD config) and the run-level energy calibration functions use, plus
`timestamp`, and for each name in `e_types` a column with the energy calibrated with the
calibration function of each run (`l200.par.rpars.ecal`, cached per process by
LegendDataManagement). The names in `e_types` are those of the calibrated energies, e.g.
`:e_cusp_ctc_cal`, whose calibration function is that of the energy without the `_cal` suffix.
An expression may use these columns; they are not read from `jldsp`.
"""
function read_hit_cal(l200::LegendData, det, runs, e_types::AbstractVector{Symbol}, expressions)
    e_types_uncal = [Symbol(first(split(string(e_type), "_cal"))) for e_type in e_types]
    # LegendDataManagement caches the parameters of each run in the process (`get_ged_cal_propfunc` would also read
    # the columns of all configured energy types)
    cal_funcs = [let sel = start_filekey(l200, (period, run, :cal))
                     [ljl_propfunc(LegendDataManagement._get_e_cal_propsfunc_str(l200, sel, DetectorId(det), e_type))
                      for e_type in e_types_uncal]
                 end
                 for (period, run) in runs]
    pfs = vcat(reduce(vcat, cal_funcs), [ljl_propfunc(expr) for expr in expressions])
    dsp_columns = Tuple(setdiff(unique(vcat(:timestamp,
                                            [first(typeof(path).parameters[1]) for pf in pfs
                                             for path in PropertyFunctions.input_property_paths(pf)])), e_types))
    @debug "Reading jldsp columns $(dsp_columns)"
    return fast_flatten([begin
                             @debug "Reading from $period-$run"
                             qc_mask = read_ldata(@pf($is_single_pulse && !$is_pulser), l200, :jlqcs,
                                                  start_filekey(l200, (period, run, :cal)), det)
                             dsp = Table(read_ldata(dsp_columns, l200, :jldsp, :cal, period, run, det))[qc_mask]
                             Table(merge(columns(dsp), NamedTuple{Tuple(e_types)}(Tuple(f.(dsp) for f in run_cal_funcs))))
                         end
                         for ((period, run), run_cal_funcs) in zip(runs, cal_funcs)])
end
