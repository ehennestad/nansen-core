function result = findPlane(entity, options, context)
%findPlane The plane of a z-stack the recording's field of view is, as dev's zStackPlaneFinder
%
%   The recording's mean image is compared with each plane at the shift the
%   phase correlation finds (within maxShift, as motion correction finds
%   one), by the Pearson correlation of the pixels both cover. The best
%   plane (from 1), its shift and the correlation of each plane (4
%   decimals). As Python's ophys_methods.find_plane.
    stack = ophys.internal.openStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    total = zeros(height, width);
    for start = 1:ophys.internal.chunk():frames
        context.checkCancelled();
        total = total + sum(double(stack.frames(start, min(start + ophys.internal.chunk() - 1, frames))), 3);
    end
    fov = total / frames;
    planes = double(all(ophys.internal.openStack(context, entity, options.zstack, struct())));
    if size(planes, 1) ~= height || size(planes, 2) ~= width
        nansen.internal.throwError("invalid-data", "the z-stack's planes are %d x %d, the recording's frames %d x %d", ...
            size(planes, 1), size(planes, 2), height, width)
    end
    shifts = ophys.internal.estimateShifts(planes, ophys.internal.referenceFft(fov, true), double(options.maxShift), false, true);
    count = size(planes, 3);
    correlations = zeros(1, count);
    for p = 1:count
        moved = ophys.internal.applyShifts(planes(:, :, p), shifts(p, :));
        covered = ophys.internal.applyShifts(ones(height, width), shifts(p, :)) > 0;
        correlations(p) = ophys.internal.roundTo(ophys.internal.pearsonOf(fov(covered), moved(covered)), 4);
    end
    [~, best] = max(correlations);   % the first of equal ones; NaN left out
    context.log("%s: plane %d of %d (r = %g)", ophys.internal.entityName(entity), best, count, correlations(best));
    result = struct("plane", best, "shift", double(shifts(best, :)), "correlation", correlations(best), ...
        "correlations", {num2cell(correlations)});
end
