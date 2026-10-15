function result = imageStats(entity, options, context)
%imageStats Size and intensity of the stack; saves its average and maximum projections, and per-frame stats
%
%   Each frame's mean, minimum, maximum and standard deviation (frames x
%   4, the population's), as dev's per-frame image stats, for plotting.
%   Reads a chunk at a time. As Python's ophys_methods.image_stats.
    stack = ophys.internal.openStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    average = zeros(height, width);
    maximum = [];
    perFrame = zeros(frames, 4);
    for start = 1:ophys.internal.chunk():frames
        part = stack.frames(start, start + ophys.internal.chunk() - 1);
        flat = reshape(double(part), height * width, []);
        perFrame(start:start + size(flat, 2) - 1, :) = [mean(flat, 1); min(flat, [], 1); max(flat, [], 1); std(flat, 1, 1)]';
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
    ophys.internal.saveIf(context, entity, nansen.internal.getField(options, "frameStatsOutput", ""), perFrame);
    context.log("%s: %d frames of %d x %d", ophys.internal.entityName(entity), frames, height, width);
    result = struct("n_frames", frames, "height", height, "width", width, ...
        "mean_intensity", ophys.internal.roundTo(total / prod(size(stack)), 4), ...
        "max_intensity", double(max(maximum, [], "all")));
end
