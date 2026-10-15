function result = denoise(entity, options, context)
%denoise Gaussian smoothing in space and in time, with the weights renormalised at the edges
    stack = ophys.internal.loadStack(context, entity, options.stack, options);
    out = double(stack);
    sigmas = [options.spatialSigma, options.spatialSigma, options.temporalSigma];
    for axis = 1:3
        context.checkCancelled();
        out = ophys.internal.gaussianAlong(out, axis, sigmas(axis));
    end
    out = single(out);
    ophys.internal.saveIf(context, entity, options.output, out);
    [height, width, frames] = size(out);
    context.log("%s: smoothed %d frames", ophys.internal.entityName(entity), frames);
    result = struct("frames", frames, "height", height, "width", width, ...
        "meanIntensity", ophys.internal.roundTo(mean(double(out), "all"), 4));
end
