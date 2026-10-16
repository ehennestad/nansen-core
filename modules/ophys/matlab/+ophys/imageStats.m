function result = imageStats(entity, options, context)
%imageStats Size and intensity of the stack; saves its average and maximum projections, and per-frame stats
%
%   Each frame's mean, minimum, maximum, standard deviation (the
%   population's), median and dev's percentiles 0.005, 0.05, 99.95 and
%   99.995 (frames x 9), as dev's PixelStatCalculator, for plotting as its
%   plotImageStats. The percentiles are linear between the sorted pixels,
%   at (n - 1) * p / 100. Reads a chunk at a time. With plane 0, of every
%   plane: the intensity of them all and of each, the projections as
%   height x width x 1 x planes x 1 (a stack of one frame per plane) and
%   the frame statistics of the planes joined (frames x 9 planes). As
%   Python's ophys_methods.image_stats.
    [~, stacks, every] = ophys.internal.planeStacks(context, entity, options.stack, options);
    [height, width, frames] = size(stacks{1});
    count = numel(stacks);
    averages = cell(1, count);
    maxima = cell(1, count);
    perFrame = cell(1, count);
    totals = zeros(1, count);
    for p = 1:count
        [averages{p}, maxima{p}, perFrame{p}, totals(p)] = planeStats(stacks{p});
    end
    ophys.internal.savePlanes(context, entity, options.averageOutput, averages, every);
    ophys.internal.savePlanes(context, entity, options.maximumOutput, maxima, every);
    ophys.internal.saveIf(context, entity, nansen.internal.getField(options, "frameStatsOutput", ""), cat(2, perFrame{:}));
    if every
        context.log("%s: %d frames of %d x %d in %d planes", ophys.internal.entityName(entity), frames, height, width, count);
    else
        context.log("%s: %d frames of %d x %d", ophys.internal.entityName(entity), frames, height, width);
    end
    pixels = height * width * frames;
    peaks = cellfun(@(m) double(max(m, [], "all")), maxima);
    result = struct("n_frames", frames, "height", height, "width", width, ...
        "mean_intensity", ophys.internal.roundTo(sum(totals) / (pixels * count), 4), ...
        "max_intensity", max(peaks));
    if every
        planes = cell(1, count);
        for p = 1:count
            planes{p} = struct("plane", p, "mean_intensity", ophys.internal.roundTo(totals(p) / pixels, 4), "max_intensity", peaks(p));
        end
        result.planes = planes;
    end
end

function [average, maximum, perFrame, total] = planeStats(stack)
    % The average and maximum projections of a height x width x frames stack, each frame's statistics (mean,
    % minimum, maximum, standard deviation, median and the percentiles), and the sum of its values, read a chunk at a time
    [height, width, frames] = size(stack);
    average = zeros(height, width);
    maximum = [];
    perFrame = zeros(frames, 9);
    for start = 1:ophys.internal.chunk():frames
        part = stack.frames(start, start + ophys.internal.chunk() - 1);
        flat = reshape(double(part), height * width, []);
        rows = start:start + size(flat, 2) - 1;
        perFrame(rows, 1:4) = [mean(flat, 1); min(flat, [], 1); max(flat, [], 1); std(flat, 1, 1)]';
        perFrame(rows, 5:9) = framePercentiles(flat);
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
end

function out = framePercentiles(flat)
    % The median and dev's percentiles (PercentileLevels 0.05 and 0.005, and 100 minus them) of each column of a
    % pixels x frames array (frames x 5), from one sort of each column: linear between the sorted values, at
    % (n - 1) * p / 100, as Python's _frame_percentiles
    percentiles = [50, 0.005, 0.05, 99.95, 99.995];
    ordered = sort(flat, 1);
    n = size(ordered, 1);
    out = zeros(size(flat, 2), numel(percentiles));
    for k = 1:numel(percentiles)
        position = (n - 1) * percentiles(k) / 100;
        low = floor(position);
        high = min(low + 1, n - 1);
        out(:, k) = (ordered(low + 1, :) + (position - low) * (ordered(high + 1, :) - ordered(low + 1, :)))';
    end
end
