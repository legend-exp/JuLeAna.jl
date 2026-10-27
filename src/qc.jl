"""
    load_qc_evaluator(l200::LegendData, filekey::FileKey)

Return the ML quality-cut evaluator for `filekey`: a function of the presummed,
baseline-subtracted waveforms that returns the columns `qc_label` and, for every
category id `k` of `dataprod_config(l200).qc(filekey).ml.categories`, the probability
`qc_prob_<k>` (`Float32`; zero for a category the model was not trained on). The model
is the one valid for `filekey` in `rpars.ml` (`load_qc_model`).

Return `missing` when no model is valid for `filekey`; the DSP processors then set
`qc_label` to `-1` and write no probabilities.
"""
function load_qc_evaluator(l200::LegendData, filekey::FileKey)
    model = load_qc_model(l200, filekey)
    ismissing(model) && return missing
    classes = sort(collect(keys(qc_categories(qc_ml_config(l200, filekey)))))
    prob_names = Tuple(Symbol.("qc_prob_", classes))
    return function (wvfs)
        labels, probabilities = predict_probabilities(model, wvfs; classes)
        return merge((qc_label = labels,),
                     NamedTuple{prob_names}(Tuple(Float32.(probabilities[:, j]) for j in axes(probabilities, 2))))
    end
end
