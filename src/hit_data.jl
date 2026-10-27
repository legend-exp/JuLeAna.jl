# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    read_hit_cal(l200::LegendData, det, runs, e_types::AbstractVector{Symbol}, expressions)

Read the single-pulse, non-pulser events (`jlqcs` tier) of the `cal` data of detector `det`
for each `(period, run)` in `runs` and return them as one `Table`.

The table has a column for each calibrated energy in `e_types` (e.g. `:e_cusp_ctc_cal`),
calibrated with the run-level calibration function of the energy without the `_cal` suffix
(`l200.par.rpars.ecal`), a `timestamp` column, and the `jldsp` columns that `expressions`
(e.g. the A/E functions of the PSD config) use. An expression may also use the calibrated
energies.
"""
function read_hit_cal(l200::LegendData, det, runs, e_types::AbstractVector{Symbol}, expressions)
    columns_out = Tuple(setdiff(union([:timestamp], _input_columns(ljl_propfunc.(expressions))), e_types))
    tables = map(collect(runs)) do (period, run)
        filekey = start_filekey(l200, (period, run, :cal))
        # LegendDataManagement keeps the parsed calibration parameters of each run in the process
        cal_funcs = [ljl_propfunc(LegendDataManagement._get_e_cal_propsfunc_str(l200, filekey, DetectorId(det),
                                                                                Symbol(chopsuffix(string(e_type), "_cal"))))
                     for e_type in e_types]
        is_qc = read_ldata(@pf($is_single_pulse && !$is_pulser), l200, :jlqcs, filekey, det)
        dsp = Table(read_ldata(Tuple(union(columns_out, _input_columns(cal_funcs))), l200, :jldsp, :cal, period, run, det))[is_qc]
        return Table(merge(columns(dsp)[columns_out], NamedTuple{Tuple(e_types)}(map(f -> f.(dsp), cal_funcs))))
    end
    return fast_flatten(tables)
end

# The names of the columns that the property functions `pfs` read
_input_columns(pfs) = unique(Symbol[_input_column(path) for pf in pfs for path in PropertyFunctions.input_property_paths(pf)])
_input_column(::PropertyFunctions.PPath{path}) where {path} = first(path)
