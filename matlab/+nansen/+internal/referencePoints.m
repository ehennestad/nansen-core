function found = referencePoints(points, entry, height, width)
%referencePoints Where points of an aligned entity's image (n x 2, from 0) are in the reference's, not rounded
%
%   The inverse of nansen.internal.alignedPoints: turned back, less the
%   shift, and the displacement field undone by 20 steps of p = u - d(p)
%   from p = u. As Python's nansen.frames.reference_points.
    points = reshape(double(points), [], 2);
    shift = reshape(double(nansen.internal.getField(entry, "shift", [0, 0])), 1, 2);
    rotation = double(nansen.internal.getField(entry, "rotation", 0));
    target = nansen.internal.turnPoints(points, -rotation, height, width) - shift;
    found = target;
    patches = double(nansen.internal.getField(entry, "patches", 1));
    if ~isempty(patches) && patches >= 2
        for step = 1:20   % Python's INVERSE_STEPS
            found = target - nansen.internal.alignmentField(found, entry, height, width);
        end
    end
end
