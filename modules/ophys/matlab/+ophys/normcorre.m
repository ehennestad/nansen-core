function result = normcorre(entity, options, context)
%normcorre Correct motion with NoRMCorre, when it is on the path: rigid with gridSize 0, piecewise rigid otherwise
%
%   Saves the aligned stack, in the stack's class, and each frame's shift
%   (frames x 2, rows then columns, averaged over the patches) as NoRMCorre
%   reports it.
    if exist("normcorre", "file") ~= 2 || exist("NoRMCorreSetParms", "file") ~= 2
        nansen.internal.throwError("dependency-missing", ...
            "ophys.normcorre needs NoRMCorre on the MATLAB path: https://github.com/flatironinstitute/NoRMCorre")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack);
    [height, width, frames] = size(stack);
    if options.gridSize == 0
        grid = [height, width];
    else
        grid = [options.gridSize, options.gridSize];
    end
    parameters = NoRMCorreSetParms("d1", height, "d2", width, "grid_size", grid, ...
        "max_shift", options.maxShift, "us_fac", options.upsampling, "print_msg", false);
    context.log("%s: running NoRMCorre on %d frames", ophys.internal.entityName(entity), frames);
    [aligned, found] = feval("normcorre", single(stack), parameters);
    shifts = zeros(frames, 2);
    for t = 1:frames
        shifts(t, :) = mean(reshape(double(found(t).shifts), [], 2), 1);
    end
    ophys.internal.saveIf(context, entity, options.output, cast(aligned, class(stack)));
    ophys.internal.saveIf(context, entity, options.shiftsOutput, shifts);
    result = struct("frames", frames, "maxShift", ophys.internal.roundTo(max([0; abs(shifts(:))]), 4));
end
