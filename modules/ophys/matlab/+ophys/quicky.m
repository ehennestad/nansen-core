function result = quicky(entity, options, context)
%quicky dev's Quicky (flufinder) ROI detection: cells as places where thresholded activity recurs
%
%   As Python's quicky, step for step: frames binned by their maximum, the
%   smooth (circular Gaussian) and slow (moving mean over 20 bins)
%   background taken out, each bin thresholded at a percentile of all
%   values and cleaned with disk-shaped morphology; areas that recur at the
%   same place in several bins make an ROI.
    stack = ophys.internal.loadStack(context, entity, options.stack, options);
    [height, width, ~] = size(stack);
    diameter = options.roiDiameter;
    binned = ophys.internal.binMax(double(stack), options.binSize);
    context.progress(0.1, "removing background");
    data = binned - ophys.internal.gaussianCircular(binned, options.smoothingSigma);
    data = data - ophys.internal.movingMean(data, 20);
    data = (data - min(data, [], "all")) / max(max(data, [], "all") - min(data, [], "all"), realmin);
    threshold = ophys.internal.percentileOf(data(:), options.binarizationPercentile);
    small = ophys.internal.diskOffsets(floor(diameter / 6 + 0.5));
    large = ophys.internal.diskOffsets(floor(diameter / 3 + 0.5));
    areas = {};
    bins = size(data, 3);
    for b = 1:bins
        context.checkCancelled();
        bw = ophys.internal.fillHoles(data(:, :, b) > threshold);
        bw = ophys.internal.dilateBy(ophys.internal.erodeBy(bw, small), small);
        bw = ophys.internal.dilateBy(bw, large);
        bw = ophys.internal.clearBorder(bw);
        bw = ophys.internal.erodeBy(bw, large);
        bw = ophys.internal.dilateBy(ophys.internal.erodeBy(bw, large), large);
        areas = [areas, ophys.internal.components(bw, 8)]; %#ok<AGROW>
        context.progress(0.1 + 0.6 * b / bins, sprintf("bin %d/%d", b, bins));
    end
    if ~isempty(areas)
        sizes = cellfun(@(a) size(a, 1), areas);
        largest = ophys.internal.percentileOf(sizes(:), 99);
        areas = areas(sizes <= largest);
    end
    rois = ophys.internal.uniqueRois(areas, height, width, diameter, options.observationsRequired, options.maxRois);
    document = struct("imageSize", [height, width], "rois", {cellfun(@(p, n) ophys.internal.makeRoi(n, p), ...
        rois, num2cell(1:numel(rois)), UniformOutput=false)});
    ophys.internal.saveIf(context, entity, options.output, document);
    context.log("%s: %d ROIs from %d areas in %d bins", ophys.internal.entityName(entity), numel(rois), numel(areas), bins);
    result = struct("rois", numel(rois), "areas", {cellfun(@(p) size(p, 1), rois, UniformOutput=false)});
end
