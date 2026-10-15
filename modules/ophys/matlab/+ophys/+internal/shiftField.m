function field = shiftField(patchShifts, rows, columns)
%shiftField One component of the patches' shifts (patches x patches), interpolated bilinearly to every pixel
    fy = rows.share;
    fx = columns.share';
    s = patchShifts;
    r0 = rows.first;
    r1 = rows.second;
    c0 = columns.first;
    c1 = columns.second;
    field = (1 - fy) .* ((1 - fx) .* s(r0, c0) + fx .* s(r0, c1)) + fy .* ((1 - fx) .* s(r1, c0) + fx .* s(r1, c1));
end
