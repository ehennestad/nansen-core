function result = deconvolve(entity, options, context)
%deconvolve Spikes and denoised calcium of each trace by OASIS (Friedrich et al. 2017), for an AR(1) or AR(2) model
%
%   order 2 is dev's default (getDeconvolutionParameters): the decay factor
%   d = exp(-1 / (tauDecay * frameRate)) and the rise factor
%   r = exp(-1 / (tauRise * frameRate)) give the coefficients as dev's
%   exp2ar does, g1 = d + r and g2 = -d r. As Python's deconvolve.
    traces = double(context.Project.load(entity, options.signals));
    rate = options.frameRate;
    if rate == 0
        rate = entity.get("frame_rate", []);
    end
    if isempty(rate) || ~isnumeric(rate) || isnan(rate) || rate == 0
        nansen.internal.throwError("invalid-options", "give frameRate, or fill in the entity's frame_rate")
    end
    order = double(nansen.internal.getField(options, "order", 2));
    g = exp(-1 / (options.tauDecay * double(rate)));
    rise = 0;
    if order == 2
        rise = exp(-1 / (double(nansen.internal.getField(options, "tauRise", 0.18)) * double(rate)));
    end
    [frames, rois] = size(traces);
    spikes = nan(frames, rois);
    calcium = nan(frames, rois);
    noise = nan(1, rois);
    for i = 1:rois
        context.checkCancelled();
        noise(i) = ophys.internal.noiseLevel(traces(:, i));
        if frames > 0 && ~any(isnan(traces(:, i)))
            if order == 2   % the slower factor decays, whichever time constant it is from
                [calcium(:, i), spikes(:, i)] = ophys.internal.oasisAr2(traces(:, i), max(g, rise), min(g, rise), options.sparsity * noise(i));
            else
                [calcium(:, i), spikes(:, i)] = ophys.internal.oasisAr1(traces(:, i), g, options.sparsity * noise(i));
            end
        end
        context.progress(i / max(rois, 1), sprintf("ROI %d/%d", i, rois));
    end
    ophys.internal.saveIf(context, entity, options.output, spikes);
    ophys.internal.saveIf(context, entity, options.denoisedOutput, calcium);
    if order == 2
        context.log("%s: deconvolved %d traces, AR(2) coefficients %.4f and %.4f", ophys.internal.entityName(entity), rois, g + rise, -g * rise);
    else
        context.log("%s: deconvolved %d traces, decay factor %.4f per frame", ophys.internal.entityName(entity), rois, g);
    end
    result = struct("rois", rois, "frames", frames, ...
        "noise", {num2cell(ophys.internal.roundTo(noise, 4))}, ...
        "spikeSum", {num2cell(ophys.internal.roundTo(sum(spikes, 1), 3))}, ...
        "maxCalcium", {num2cell(ophys.internal.roundTo(max(calcium, [], 1), 3))});
end
