function result = crop(entity, options, context)
%crop Rows, columns and frames of the stack saved as a new stack, as dev's StackCropper
%
%   firstRow..lastRow, firstColumn..lastColumn and firstFrame..lastFrame,
%   from 1, 0 for the last. Read and written a chunk at a time. As Python's
%   ophys_methods.crop.
    stack = ophys.internal.openStack(context, entity, options.stack, options);   % frames firstFrame..lastFrame
    [height, width, frames] = size(stack);
    [top, bottom] = span(options.firstRow, options.lastRow, height, "rows");
    [left, right] = span(options.firstColumn, options.lastColumn, width, "columns");
    dimensions = [bottom - top + 1, right - left + 1, frames];
    checkpoint = context.Project.checkpoint(entity, options.output, dimensions, stack.ClassName, options, stack, Method=context.Method);
    writer = checkpoint.writer();   % a run that stopped goes on where it stopped (nansen.Checkpoint)
    closer = onCleanup(@() writer.close());
    for start = 1 + checkpoint.FramesDone:ophys.internal.chunk():frames
        context.checkCancelled();
        stop = min(start + ophys.internal.chunk() - 1, frames);
        part = stack.frames(start, stop);
        writer.write(start, part(top:bottom, left:right, :));
        checkpoint.save(1, stop);
        context.progress(stop / frames, sprintf("frame %d/%d", stop, frames));
    end
    writer.close();
    checkpoint.finish();
    context.log("%s: %d x %d x %d kept", ophys.internal.entityName(entity), dimensions(1), dimensions(2), dimensions(3));
    result = struct("height", dimensions(1), "width", dimensions(2), "frames", dimensions(3));
end

function [first, last] = span(first, last, count, what)
    first = double(first);
    last = double(last);
    if last == 0
        last = count;
    end
    if ~(1 <= first && first <= last && last <= count)
        nansen.internal.throwError("invalid-options", "%s %d to %d are not within the stack's %d", what, first, last, count)
    end
end
