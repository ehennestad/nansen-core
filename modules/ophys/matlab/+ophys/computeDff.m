function result = computeDff(entity, options, context)
%computeDff ΔF/F of each ROI by one of dev's methods, with F0 a running or overall percentile
%
%   subtract: F = signal - k neuropil, ΔF/F = (F - F0) / F0. chen2013 (Chen
%   et al. 2013, as dev's dffChenEtAl2013): the neuropil's own baseline
%   added back, F = signal - k neuropil + N0. dffMinusNeuropil (dev's
%   dffRoiMinusDffNpil, without its smoothing): the signal's ΔF/F less k
%   times the neuropil's. A correctionWindow > 0 then subtracts a running
%   correctionPercentile of ΔF/F over that many frames, as dev's
%   correctBaseline. As Python's ophys_methods.compute_dff.
    signals = double(context.Project.load(entity, options.signals));
    method = string(nansen.internal.getField(options, "method", "subtract"));
    k = options.neuropilFactor;
    p = options.baselinePercentile;
    window = options.baselineWindow;
    neuropil = [];
    if strlength(string(options.neuropil)) > 0
        neuropil = double(context.Project.load(entity, options.neuropil));
        if ~isequal(size(neuropil), size(signals))
            nansen.internal.throwError("invalid-data", "the neuropil signals are %s, the signals %s", ...
                mat2str(size(neuropil)), mat2str(size(signals)))
        end
        neuropil(isnan(neuropil)) = 0;
    elseif method == "dffMinusNeuropil"
        nansen.internal.throwError("invalid-options", "dffMinusNeuropil needs the neuropil signals")
    end
    if method == "dffMinusNeuropil"
        baseline = ophys.internal.movingPercentile(signals, p, window);
        neuropilBaseline = ophys.internal.movingPercentile(neuropil, p, window);
        dff = (signals - baseline) ./ baseline - k * (neuropil - neuropilBaseline) ./ neuropilBaseline;
    else
        if ~isempty(neuropil)
            signals = signals - k * neuropil;
            if method == "chen2013"
                signals = signals + ophys.internal.movingPercentile(neuropil, p, window);
            end
        end
        baseline = ophys.internal.movingPercentile(signals, p, window);
        dff = (signals - baseline) ./ baseline;
    end
    correction = nansen.internal.getField(options, "correctionWindow", 0);
    if correction > 0
        dff = dff - ophys.internal.movingPercentile(dff, nansen.internal.getField(options, "correctionPercentile", 25), correction);
    end
    ophys.internal.saveIf(context, entity, options.output, dff);
    [frames, rois] = size(signals);
    context.log("%s: ΔF/F of %d ROIs", ophys.internal.entityName(entity), rois);
    result = struct("rois", rois, "frames", frames, ...
        "baseline", {num2cell(ophys.internal.roundTo(mean(baseline, 1), 4))}, ...
        "maxDff", {num2cell(ophys.internal.roundTo(max(dff, [], 1), 4))});
end
