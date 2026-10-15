function result = imageStats(entity, options, context)
%imageStats Size and intensity of the stack; saves its average and maximum projections. Reads a chunk at a time.
    stack = ophys.internal.openStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    average = zeros(height, width);
    maximum = [];
    for start = 1:ophys.internal.chunk():frames
        part = stack.frames(start, start + ophys.internal.chunk() - 1);
        average = average + sum(double(part), 3);
        peak = max(part, [], 3);
        if isempty(maximum)
            maximum = peak;
        else
            maximum = max(maximum, peak);
        end
    end
    total = sum(average, "all");
    average = average / frames;
    ophys.internal.saveIf(context, entity, options.averageOutput, average);
    ophys.internal.saveIf(context, entity, options.maximumOutput, maximum);
    context.log("%s: %d frames of %d x %d", ophys.internal.entityName(entity), frames, height, width);
    result = struct("n_frames", frames, "height", height, "width", width, ...
        "mean_intensity", ophys.internal.roundTo(total / prod(size(stack)), 4), ...
        "max_intensity", double(max(maximum, [], "all")));
end
