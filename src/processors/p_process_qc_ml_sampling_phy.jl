"""
    p_process_qc_ml_sampling_phy(processing_config, l200::LegendData, period::DataPeriod;
        reprocess::Bool=false, only_first_period::Bool=true) -> Bool

[`p_process_qc_ml_sampling_cal`](@ref) for the `phy` data of `period`: the report is `qc_ml_sampling_phy`.
"""
function p_process_qc_ml_sampling_phy(processing_config, l200::LegendData, period::DataPeriod; reprocess::Bool = false,
                                      only_first_period::Bool = true)
    fk = training_filekey(l200, period, DataCategory(:phy))
    report = qc_ml_sampling(l200, fk; reprocess)
    isnothing(report) || write_report(get_preportfilename(l200, fk, :qc_ml_sampling_phy), report)
    return false
end

register_processor!(p_process_qc_ml_sampling_phy; output_tiers = [:jlqml], detector_selection = false)
