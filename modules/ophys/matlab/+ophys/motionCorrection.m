function result = motionCorrection(entity, options, context)
%motionCorrection Align each frame to a reference by the whole-pixel shift of largest (smoothed) phase correlation
%
%   The reference is the average of the first referenceFrames frames; each
%   further iteration uses the average of the frames aligned in the one before.
    stack = ophys.internal.loadStack(context, entity, options.stack);
    [height, width, frames] = size(stack);
    count = min(options.referenceFrames, frames);
    reference = mean(double(stack(:, :, 1:count)), 3);
    filter = ophys.internal.smoothing(height, width);
    iterations = options.iterations;
    for iteration = 1:iterations
        shifts = zeros(frames, 2);
        referenceFft = conj(fft2(reference)) .* filter;
        for start = 1:ophys.internal.chunk():frames
            context.checkCancelled();
            stop = min(start + ophys.internal.chunk() - 1, frames);
            shifts(start:stop, :) = ophys.internal.estimateShifts(stack(:, :, start:stop), referenceFft, options.maxShift);
            context.progress(((iteration - 1) * frames + stop) / (iterations * frames), ...
                sprintf("iteration %d: frame %d/%d", iteration, stop, frames));
        end
        aligned = ophys.internal.applyShifts(stack, shifts);
        reference = mean(double(aligned), 3);
    end
    ophys.internal.saveIf(context, entity, options.output, aligned);
    ophys.internal.saveIf(context, entity, options.shiftsOutput, int32(shifts));
    largest = max([0; abs(shifts(:))]);
    context.log("%s: largest shift %d px", ophys.internal.entityName(entity), largest);
    result = struct("frames", frames, "maxShift", largest, ...
        "meanShift", ophys.internal.roundTo(mean(sqrt(sum(shifts .^ 2, 2))), 4));
end
