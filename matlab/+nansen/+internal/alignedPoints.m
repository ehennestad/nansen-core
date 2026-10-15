function points = alignedPoints(points, entry, height, width)
%alignedPoints Where points of the reference's image (n x 2: rows, columns, from 0) are in an aligned entity's, not rounded
%
%   entry is the entity's entry of an ROI file's alignment (ophys.alignSessions
%   writes it): its shift, rotation and, with patches, the patches' rowShifts
%   and columnShifts. A point p goes to rotation * (p + d(p) + shift -
%   centre) + centre, d the displacement field (nansen.internal.alignmentField).
%   As Python's nansen.frames.aligned_points.
    points = reshape(double(points), [], 2);
    shift = reshape(double(nansen.internal.getField(entry, "shift", [0, 0])), 1, 2);
    moved = points + nansen.internal.alignmentField(points, entry, height, width) + shift;
    points = nansen.internal.turnPoints(moved, double(nansen.internal.getField(entry, "rotation", 0)), height, width);
end
