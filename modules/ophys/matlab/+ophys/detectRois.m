function result = detectRois(entity, options, context)
%detectRois ROIs as 4-connected areas of pixels whose average correlation with their 8 neighbours reaches the threshold
%
%   Reads the stack a chunk at a time. With plane 0, the ROIs of every
%   plane, in one file: each with its plane and channel (from 1), the first
%   plane's first, numbered on from one plane to the next. As Python's
%   ophys_methods.detect_rois.
    [~, stacks, every] = ophys.internal.planeStacks(context, entity, options.stack, options);
    [height, width, ~] = size(stacks{1});
    border = options.border;
    found = cell(1, numel(stacks));
    for p = 1:numel(stacks)
        image = ophys.internal.correlationImage(stacks{p});
        image([1:min(border, height), max(1, height - border + 1):height], :) = -Inf;
        image(:, [1:min(border, width), max(1, width - border + 1):width]) = -Inf;
        areas = ophys.internal.components(image >= options.threshold);
        kept = {};
        for i = 1:numel(areas)
            if size(areas{i}, 1) >= options.minSize && size(areas{i}, 1) <= options.maxSize
                kept{end + 1} = areas{i}; %#ok<AGROW>
            end
        end
        found{p} = kept;
    end
    rois = ophys.internal.placedRois(found, every, options);
    ophys.internal.saveIf(context, entity, options.output, struct("imageSize", [height, width], "rois", {rois}));
    context.log("%s: %d ROIs", ophys.internal.entityName(entity), numel(rois));
    result = struct("rois", numel(rois), "areas", {cellfun(@(r) r.area, rois, UniformOutput=false)});
    if every
        result.planes = cellfun(@(f, p) struct("plane", p, "rois", numel(f)), found, num2cell(1:numel(found)), UniformOutput=false);
    end
end
