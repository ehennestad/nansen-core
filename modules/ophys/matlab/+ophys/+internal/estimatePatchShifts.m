function shifts = estimatePatchShifts(frames, patchFfts, rowEdges, columnEdges, rigid, maxShift, deviation, subpixel)
%estimatePatchShifts The shift of each patch of each frame: n x 2 x patches x patches
%
%   A patch's peak is looked for within deviation of the frame's whole-pixel
%   shift (rigid, n x 2), within maxShift and less than half the patch;
%   where that leaves nothing, the patch takes the frame's shift. Patch i
%   is rows rowEdges(i) to rowEdges(i + 1) - 1 (from 0), as in Python.
    n = size(frames, 3);
    patches = numel(rowEdges) - 1;
    shifts = zeros(n, 2, patches, patches);
    for i = 1:patches
        for j = 1:patches
            r0 = rowEdges(i);
            r1 = rowEdges(i + 1);
            c0 = columnEdges(j);
            c1 = columnEdges(j + 1);
            [correlation, product] = ophys.internal.correlation(ophys.internal.tapered(frames(r0 + 1:r1, c0 + 1:c1, :)), patchFfts{i, j});
            for t = 1:n
                rows = ophys.internal.shiftRange(rigid(t, 1), deviation, maxShift, floor((r1 - r0 - 1) / 2));
                columns = ophys.internal.shiftRange(rigid(t, 2), deviation, maxShift, floor((c1 - c0 - 1) / 2));
                if ~isempty(rows) && ~isempty(columns)
                    [shifts(t, 1, i, j), shifts(t, 2, i, j)] = ophys.internal.peak(correlation(:, :, t), product(:, :, t), rows, columns, subpixel);
                else
                    shifts(t, :, i, j) = rigid(t, :);
                end
            end
        end
    end
end
