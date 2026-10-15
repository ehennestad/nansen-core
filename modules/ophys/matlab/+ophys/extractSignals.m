function result = extractSignals(entity, options, context)
%extractSignals Average of each ROI's pixels per frame (frames x ROIs), and of a ring of neuropil around it outside every ROI
    stack = ophys.internal.loadStack(context, entity, options.stack);
    [height, width, frames] = size(stack);
    masks = ophys.internal.roiMasks(context.Project.load(entity, options.rois), height, width);
    flat = reshape(stack, height * width, frames);
    count = numel(masks);
    signals = nan(frames, count);
    neuropil = nan(frames, count);
    union = false(height, width);
    for i = 1:count
        union = union | masks{i};
    end
    for i = 1:count
        context.checkCancelled();
        signals(:, i) = mean(double(flat(masks{i}(:), :)), 1)';
        ring = ophys.internal.dilate(masks{i}, options.neuropilGap + options.neuropilWidth) ...
            & ~ophys.internal.dilate(masks{i}, options.neuropilGap) & ~union;
        if any(ring, "all")
            neuropil(:, i) = mean(double(flat(ring(:), :)), 1)';
        end
        context.progress(i / count, sprintf("ROI %d/%d", i, count));
    end
    ophys.internal.saveIf(context, entity, options.output, signals);
    ophys.internal.saveIf(context, entity, options.neuropilOutput, neuropil);
    context.log("%s: signals of %d ROIs in %d frames", ophys.internal.entityName(entity), count, frames);
    result = struct("rois", count, "frames", frames, ...
        "meanSignal", {num2cell(ophys.internal.roundTo(mean(signals, 1), 4))}, ...
        "meanNeuropil", {num2cell(ophys.internal.roundTo(mean(neuropil, 1), 4))});
end
