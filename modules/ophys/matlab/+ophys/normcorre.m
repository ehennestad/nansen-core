function result = normcorre(entity, options, context)
%normcorre Correct motion with NoRMCorre, when it is on the path: rigid with gridSize 0, piecewise rigid otherwise
%
%   Saves the aligned stack, in the stack's class, and each frame's shift
%   (frames x 2, rows then columns, averaged over the patches) as NoRMCorre
%   reports it. patches above 0 cuts the frame into patches x patches
%   patches (grid_size round([height, width] / patches), as dev's numRows
%   and numCols); the other options are NoRMCorre's max_shift, us_fac,
%   max_dev, overlap_pre, iter, upd_template, init_batch and bin_width.
    if exist("normcorre", "file") ~= 2 || exist("NoRMCorreSetParms", "file") ~= 2
        nansen.internal.throwError("dependency-missing", ...
            "ophys.normcorre needs NoRMCorre on the MATLAB path: https://github.com/flatironinstitute/NoRMCorre")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    patches = double(nansen.internal.getField(options, "patches", 0));
    if patches > 0   % dev's numRows and numCols
        grid = max(1, round([height, width] ./ patches));
    elseif options.gridSize == 0
        grid = [height, width];
    else
        grid = [options.gridSize, options.gridSize];
    end
    % NoRMCorreSetParms takes char names (not strings)
    parameters = NoRMCorreSetParms('d1', height, 'd2', width, 'grid_size', grid, ...
        'max_shift', double(options.maxShift), 'us_fac', double(options.upsampling), 'print_msg', false, ...
        'max_dev', double(nansen.internal.getField(options, "maxDeviation", 3)), ...
        'overlap_pre', double(nansen.internal.getField(options, "overlap", 32)), ...
        'iter', double(nansen.internal.getField(options, "iterations", 1)), ...
        'upd_template', logical(nansen.internal.getField(options, "updateTemplate", true)), ...
        'init_batch', double(nansen.internal.getField(options, "initialBatchSize", 100)), ...
        'bin_width', double(nansen.internal.getField(options, "binWidth", 200)));
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
