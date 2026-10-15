function field = alignmentField(points, entry, height, width)
%alignmentField The displacement field of an aligned entity's patches at points (n x 2: rows, columns, from 0): n x 2
%
%   entry is the entity's entry of an ROI file's alignment: with patches
%   (2 or more), rowShifts and columnShifts hold each patch's displacement,
%   patch (i, j) (from 0) at i * patches + j. Between the patch centres the
%   displacements are interpolated bilinearly, as the motion correction's
%   patches; before the first centre or after the last, that patch's alone.
%   Zero without patches. As Python's nansen.frames._displacement.
    count = double(nansen.internal.getField(entry, "patches", 1));
    if isempty(count)
        count = 1;
    end
    field = zeros(size(points));
    if count < 2
        return
    end
    [r0, r1, fy] = place(points(:, 1), height, count);
    [c0, c1, fx] = place(points(:, 2), width, count);
    names = ["rowShifts", "columnShifts"];
    for axis = 1:2
        s = reshape(double(entry.(names(axis))), count, count).';   % s(i, j) is patch (i, j), from the row-major list
        at = @(r, c) s(sub2ind([count, count], r, c));
        field(:, axis) = (1 - fy) .* ((1 - fx) .* at(r0, c0) + fx .* at(r0, c1)) + fy .* ((1 - fx) .* at(r1, c0) + fx .* at(r1, c1));
    end
end

function [first, second, share] = place(coordinates, size_, count)
    % The patches (from 1) whose centres each coordinate lies between, and how far it is from the first (0..1)
    edges = floor((0:count) * size_ / count);
    centres = (edges(1:end - 1) + edges(2:end) - 1) / 2;
    n = numel(coordinates);
    first = ones(n, 1);
    second = ones(n, 1);
    share = zeros(n, 1);
    for k = 1:n
        y = coordinates(k);
        if y <= centres(1)
            continue
        end
        if y >= centres(end)
            first(k) = count;
            second(k) = count;
            continue
        end
        i = sum(centres <= y);
        first(k) = i;
        second(k) = i + 1;
        share(k) = (y - centres(i)) / (centres(i + 1) - centres(i));
    end
end
