function result = motionCorrection(entity, options, context)
%motionCorrection Align each frame to a reference by the whole-pixel shift of largest (smoothed) phase correlation
%
%   The reference is the average of the first referenceFrames frames; each
%   further iteration uses the average of the frames aligned in the one
%   before. The stack is read a chunk at a time and the aligned stack
%   written the same way, so a recording need not fit in memory.
    stack = ophys.internal.openStack(context, entity, options.stack);
    [height, width, frames] = size(stack);
    count = min(options.referenceFrames, frames);
    reference = mean(double(stack.frames(1, count)), 3);
    filter = ophys.internal.smoothing(height, width);
    iterations = options.iterations;
    for iteration = 1:iterations
        last = iteration == iterations;
        shifts = zeros(frames, 2);
        referenceFft = conj(fft2(reference)) .* filter;
        total = zeros(height, width);
        if last
            writer = context.Project.stackWriter(entity, options.output, [height, width, frames], stack.ClassName);
        end
        for start = 1:ophys.internal.chunk():frames
            context.checkCancelled();
            stop = min(start + ophys.internal.chunk() - 1, frames);
            chunk = stack.frames(start, stop);
            shifts(start:stop, :) = ophys.internal.estimateShifts(chunk, referenceFft, options.maxShift);
            aligned = ophys.internal.applyShifts(chunk, shifts(start:stop, :));
            if last
                writer.write(start, aligned);
            else
                total = total + sum(double(aligned), 3);
            end
            context.progress(((iteration - 1) * frames + stop) / (iterations * frames), ...
                sprintf("iteration %d: frame %d/%d", iteration, stop, frames));
        end
        if last
            writer.close();
        end
        reference = total / frames;
    end
    ophys.internal.saveIf(context, entity, options.shiftsOutput, int32(shifts));
    largest = max([0; abs(shifts(:))]);
    context.log("%s: largest shift %d px", ophys.internal.entityName(entity), largest);
    result = struct("frames", frames, "maxShift", largest, ...
        "meanShift", ophys.internal.roundTo(mean(sqrt(sum(shifts .^ 2, 2))), 4));
end
