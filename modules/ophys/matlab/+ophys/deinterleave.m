function result = deinterleave(entity, options, context)
%deinterleave Frames of several channels and planes, interleaved in one stack, as height x width x channels (x planes) x frames
%
%   Channel fastest, then plane, as ScanImage saves them. Frames after the
%   last whole volume are left out. Reads and writes a chunk at a time.
%   firstFrame..lastFrame count the frames put together (volumes): frame k
%   is the stack's frames (k - 1) x channels x planes + 1 to k x channels x
%   planes. As Python's ophys_methods.deinterleave.
    channels = double(options.channels);
    planes = double(options.planes);
    per = channels * planes;
    stack = ophys.internal.pick(ophys.internal.openWhole(context, entity, options.stack, options, per), options.stack, 1, 1);
    [height, width, total] = size(stack);
    frames = floor(total / per);
    if frames == 0
        nansen.internal.throwError("invalid-options", "%s has %d frames, fewer than %d channels x %d planes", options.stack, total, channels, planes)
    end
    if planes > 1
        shape = [height, width, channels, planes, frames];
    elseif channels > 1
        shape = [height, width, channels, frames];
    else
        shape = [height, width, frames];
    end
    step = max(1, floor(ophys.internal.chunk() / per));
    checkpoint = context.Project.checkpoint(entity, options.output, shape, stack.ClassName, options, stack, Method=context.Method);
    writer = checkpoint.writer();   % a run that stopped goes on where it stopped (nansen.Checkpoint)
    for first = checkpoint.FramesDone + 1:step:frames
        context.checkCancelled();
        last = min(first + step - 1, frames);
        n = last - first + 1;
        chunk = stack.frames((first - 1) * per + 1, last * per);
        % frame k of the chunk is channel c, plane p, volume v with k = ((v - 1) * planes + (p - 1)) * channels + c
        writer.write(first, reshape(chunk, [shape(1:end - 1), n]));
        checkpoint.save(1, last);
        context.progress(last / frames, sprintf("frame %d/%d", last, frames));
    end
    writer.close();
    checkpoint.finish();
    context.log("%s: %d frames of %d channel(s) and %d plane(s)", ophys.internal.entityName(entity), frames, channels, planes);
    result = struct("frames", frames, "channels", channels, "planes", planes);
end
