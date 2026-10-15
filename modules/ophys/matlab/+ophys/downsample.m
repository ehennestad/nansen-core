function result = downsample(entity, options, context)
%downsample Bin the stack: mean (single precision) or maximum of each bin of frames and of pixels
    stack = ophys.internal.loadStack(context, entity, options.stack);
    factor = options.temporalFactor;
    side = options.spatialFactor;
    height = floor(size(stack, 1) / side);
    width = floor(size(stack, 2) / side);
    frames = floor(size(stack, 3) / factor);
    if frames == 0 || height == 0 || width == 0
        nansen.internal.throwError("invalid-options", "the stack %s is smaller than one bin", mat2str(size(stack)))
    end
    byMean = options.binMethod == "mean";
    if byMean
        out = zeros(height, width, frames, "single");
    else
        out = zeros(height, width, frames, "like", stack);
    end
    step = max(1, floor(ophys.internal.chunk() / factor));
    for first = 0:step:frames - 1
        context.checkCancelled();
        last = min(first + step, frames);
        bins = reshape(stack(1:height * side, 1:width * side, first * factor + 1:last * factor), ...
            side, height, side, width, factor, last - first);
        if byMean
            out(:, :, first + 1:last) = single(reshape(mean(double(bins), [1, 3, 5]), height, width, last - first));
        else
            out(:, :, first + 1:last) = reshape(max(bins, [], [1, 3, 5]), height, width, last - first);
        end
        context.progress(last / frames, sprintf("frame %d/%d", last, frames));
    end
    ophys.internal.saveIf(context, entity, options.output, out);
    context.log("%s: %d frames of %d x %d", ophys.internal.entityName(entity), frames, height, width);
    result = struct("frames", frames, "height", height, "width", width, ...
        "meanIntensity", ophys.internal.roundTo(mean(double(out), "all"), 4));
end
