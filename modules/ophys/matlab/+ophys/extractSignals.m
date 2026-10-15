function result = extractSignals(entity, options, context)
%extractSignals Average of each ROI's pixels per frame (frames x ROIs), and of neuropil around it outside every ROI
%
%   Reads the stack a chunk at a time. With excludeOverlaps (dev's
%   excludeRoiOverlaps), pixels in more than one ROI are left out of the
%   ROIs' signals. The neuropil is a ring (neuropilGap pixels from the ROI,
%   neuropilWidth wide), or with neuropilMethod "expansion" dev's (see
%   ophys.internal.expansionNeuropil). As Python's ophys_methods.extract_signals.
    stack = ophys.internal.openStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    document = context.Project.load(entity, options.rois);
    rois = ophys.internal.roiList(document);
    keep = cellfun(@(r) options.includeRejected || ~strcmp(string(nansen.internal.getField(r, "classification", "")), "rejected"), rois);
    rois = rois(keep);
    ids = cell(1, numel(rois));
    for i = 1:numel(rois)
        ids{i} = nansen.internal.getField(rois{i}, "id", i);
    end
    document.rois = rois;
    masks = ophys.internal.roiMasks(document, height, width);
    count = numel(masks);
    signals = nan(frames, count);
    neuropil = nan(frames, count);
    union = false(height, width);
    covered = zeros(height, width);
    for i = 1:count
        union = union | masks{i};
        covered = covered + masks{i};
    end
    own = masks;
    if nansen.internal.getField(options, "excludeOverlaps", false)
        own = cellfun(@(m) m & covered == 1, masks, UniformOutput=false);
    end
    if string(nansen.internal.getField(options, "neuropilMethod", "ring")) == "expansion"
        rings = ophys.internal.expansionNeuropil(masks, union, nansen.internal.getField(options, "neuropilExpansionFactor", 4), ...
            nansen.internal.getField(options, "neuropilSeparation", 0));
    else
        rings = cell(1, count);
        for i = 1:count
            rings{i} = ophys.internal.dilate(masks{i}, options.neuropilGap + options.neuropilWidth) ...
                & ~ophys.internal.dilate(masks{i}, options.neuropilGap) & ~union;
        end
    end
    for start = 1:ophys.internal.chunk():frames
        context.checkCancelled();
        stop = min(start + ophys.internal.chunk() - 1, frames);
        flat = reshape(stack.frames(start, stop), height * width, stop - start + 1);
        for i = 1:count
            if any(own{i}, "all")
                signals(start:stop, i) = mean(double(flat(own{i}(:), :)), 1)';
            end
            if any(rings{i}, "all")
                neuropil(start:stop, i) = mean(double(flat(rings{i}(:), :)), 1)';
            end
        end
        context.progress(stop / frames, sprintf("frame %d/%d", stop, frames));
    end
    ophys.internal.saveIf(context, entity, options.output, signals);
    ophys.internal.saveIf(context, entity, options.neuropilOutput, neuropil);
    context.log("%s: signals of %d ROIs in %d frames", ophys.internal.entityName(entity), count, frames);
    result = struct("rois", count, "frames", frames, "ids", {ids}, ...
        "meanSignal", {num2cell(ophys.internal.roundTo(mean(signals, 1), 4))}, ...
        "meanNeuropil", {num2cell(ophys.internal.roundTo(mean(neuropil, 1), 4))});
end
