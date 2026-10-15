function result = computeDff(entity, options, context)
%computeDff (F - F0) / F0, with F the signal less a share of the neuropil and F0 a running or overall percentile
    signals = double(context.Project.load(entity, options.signals));
    if strlength(string(options.neuropil)) > 0
        neuropil = double(context.Project.load(entity, options.neuropil));
        if ~isequal(size(neuropil), size(signals))
            nansen.internal.throwError("invalid-data", "the neuropil signals are %s, the signals %s", ...
                mat2str(size(neuropil)), mat2str(size(signals)))
        end
        neuropil(isnan(neuropil)) = 0;
        signals = signals - options.neuropilFactor * neuropil;
    end
    baseline = ophys.internal.movingPercentile(signals, options.baselinePercentile, options.baselineWindow);
    dff = (signals - baseline) ./ baseline;
    ophys.internal.saveIf(context, entity, options.output, dff);
    [frames, rois] = size(signals);
    context.log("%s: ΔF/F of %d ROIs", ophys.internal.entityName(entity), rois);
    result = struct("rois", rois, "frames", frames, ...
        "baseline", {num2cell(ophys.internal.roundTo(mean(baseline, 1), 4))}, ...
        "maxDff", {num2cell(ophys.internal.roundTo(max(dff, [], 1), 4))});
end
