"""
    load_qc_evaluator(l200::LegendData, filekey::FileKey)

Return the ML quality-cut evaluator for `filekey`. The ML quality cut is disabled: return
`missing` and log an info message. The DSP processors skip the Haar wavelet classification
when the evaluator is `missing` and set `qc_label` to `-1`.
"""
function load_qc_evaluator(l200::LegendData, filekey::FileKey)
    @info "The ML quality cut is disabled - skipping ML QC for $filekey"
    return missing
end
