function result = denoise(entity, options, context)
%denoise Gaussian smoothing in space and in time, with the weights renormalised at the edges
%
%   Read and written a chunk at a time: each part with 3 temporal sigmas of
%   frames on either side, so every frame gets the weights it would get
%   were the stack smoothed whole; as Python's denoise.
    stack = ophys.internal.openStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    temporal = options.temporalSigma;
    halo = 0;
    if temporal > 0
        halo = ceil(3 * temporal);
    end
    step = max(1, ophys.internal.chunk() - 2 * halo);   % each read, halo included, is a chunk at most
    sigmas = [options.spatialSigma, options.spatialSigma, temporal];
    writer = context.Project.stackWriter(entity, options.output, [height, width, frames], "single");
    total = 0;
    for start = 1:step:frames
        context.checkCancelled();
        stop = min(start + step - 1, frames);
        first = max(1, start - halo);
        last = min(frames, stop + halo);
        block = double(stack.frames(first, last));
        for axis = 1:3
            block = ophys.internal.gaussianAlong(block, axis, sigmas(axis));
        end
        piece = single(block(:, :, start - first + 1:stop - first + 1));
        writer.write(start, piece);
        total = total + sum(double(piece), "all");
        context.progress(stop / frames, sprintf("frame %d/%d", stop, frames));
    end
    writer.close();
    context.log("%s: smoothed %d frames", ophys.internal.entityName(entity), frames);
    result = struct("frames", frames, "height", height, "width", width, ...
        "meanIntensity", ophys.internal.roundTo(total / (height * width * frames), 4));
end
