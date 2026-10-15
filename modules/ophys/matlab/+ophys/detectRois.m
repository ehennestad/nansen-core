function result = detectRois(entity, options, context)
%detectRois ROIs as 4-connected areas of pixels whose average correlation with their 8 neighbours reaches the threshold
    stack = ophys.internal.loadStack(context, entity, options.stack, options);
    [height, width, ~] = size(stack);
    image = ophys.internal.correlationImage(stack);
    border = options.border;
    image([1:min(border, height), max(1, height - border + 1):height], :) = -Inf;
    image(:, [1:min(border, width), max(1, width - border + 1):width]) = -Inf;
    rois = {};
    areas = {};
    found = ophys.internal.components(image >= options.threshold);
    for i = 1:numel(found)
        pixels = found{i};
        if size(pixels, 1) >= options.minSize && size(pixels, 1) <= options.maxSize
            rois{end + 1} = ophys.internal.makeRoi(numel(rois) + 1, pixels); %#ok<AGROW>
            areas{end + 1} = size(pixels, 1); %#ok<AGROW>
        end
    end
    ophys.internal.saveIf(context, entity, options.output, struct("imageSize", [height, width], "rois", {rois}));
    context.log("%s: %d ROIs", ophys.internal.entityName(entity), numel(rois));
    result = struct("rois", numel(rois), "areas", {areas});
end
