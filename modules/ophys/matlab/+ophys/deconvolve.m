function result = deconvolve(entity, options, context)
%deconvolve Spikes and denoised calcium of each trace by OASIS for an AR(1) model (Friedrich et al. 2017)
    traces = double(context.Project.load(entity, options.signals));
    rate = options.frameRate;
    if rate == 0
        rate = entity.get("frame_rate", []);
    end
    if isempty(rate) || ~isnumeric(rate) || isnan(rate) || rate == 0
        nansen.internal.throwError("invalid-options", "give frameRate, or fill in the entity's frame_rate")
    end
    g = exp(-1 / (options.tauDecay * double(rate)));
    [frames, rois] = size(traces);
    spikes = nan(frames, rois);
    calcium = nan(frames, rois);
    noise = nan(1, rois);
    for i = 1:rois
        context.checkCancelled();
        noise(i) = ophys.internal.noiseLevel(traces(:, i));
        if frames > 0 && ~any(isnan(traces(:, i)))
            [calcium(:, i), spikes(:, i)] = ophys.internal.oasisAr1(traces(:, i), g, options.sparsity * noise(i));
        end
        context.progress(i / max(rois, 1), sprintf("ROI %d/%d", i, rois));
    end
    ophys.internal.saveIf(context, entity, options.output, spikes);
    ophys.internal.saveIf(context, entity, options.denoisedOutput, calcium);
    context.log("%s: deconvolved %d traces, decay factor %.4f per frame", ophys.internal.entityName(entity), rois, g);
    result = struct("rois", rois, "frames", frames, ...
        "noise", {num2cell(ophys.internal.roundTo(noise, 4))}, ...
        "spikeSum", {num2cell(ophys.internal.roundTo(sum(spikes, 1), 3))}, ...
        "maxCalcium", {num2cell(ophys.internal.roundTo(max(calcium, [], 1), 3))});
end
