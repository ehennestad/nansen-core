function roi = makeRoi(number, pixels)
%makeRoi An ROI of the ROI file from its 1-based [row, column] pixels; the file has them 0-based
    roi = struct();
    roi.id = number;
    roi.area = size(pixels, 1);
    roi.center = [ophys.internal.roundTo(mean(pixels(:, 1)) - 1, 2), ophys.internal.roundTo(mean(pixels(:, 2)) - 1, 2)];
    roi.pixels = num2cell(pixels - 1, 2)';   % a list of [row, column] pairs, also for one pixel
end
