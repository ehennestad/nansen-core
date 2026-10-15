function result = quicky(entity, options, context)
%quicky dev's Quicky (flufinder) ROI detection: cells as places where thresholded activity recurs
%
%   As Python's quicky, step for step: frames binned by their maximum, the
%   smooth (circular Gaussian) and slow (moving mean over 20 bins)
%   background taken out, each bin thresholded at a percentile of all
%   values and cleaned with disk-shaped morphology; areas that recur at the
%   same place in several bins make an ROI. With useShapeDetection, somata
%   found by their shape in the mean image (ophys.internal.shapeRois) come
%   first, and activity ROIs overlapping one by more than 75 % are left out.
    stack = ophys.internal.openStack(context, entity, options.stack, options);   % read a chunk of bins at a time
    [height, width, ~] = size(stack);
    diameter = options.roiDiameter;
    useShape = logical(nansen.internal.getField(options, "useShapeDetection", false));
    [binned, average] = ophys.internal.binnedMax(stack, options.binSize, useShape);
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
    shaped = {};
    if useShape   % somata seen by their shape in the mean image, first
        context.progress(0.8, "shape detection");
        shaped = ophys.internal.shapeRois(average, double(nansen.internal.getField(options, "innerRadius", 3)), ...
            double(nansen.internal.getField(options, "outerRadius", 5)));
        keep = cellfun(@(r) ~any(cellfun(@(s) ophys.internal.overlapShare(r, s) > 0.75, shaped)), rois);
        rois = [reshape(shaped, 1, []), reshape(rois(keep), 1, [])];
        rois = rois(1:min(numel(rois), options.maxRois));
    end
    rois = reshape(rois, 1, []);   % 1 x 0 when none were found, as num2cell(1:0) is
    document = struct("imageSize", [height, width], "rois", {cellfun(@(p, n) ophys.internal.makeRoi(n, p), ...
        rois, num2cell(1:numel(rois)), UniformOutput=false)});
    ophys.internal.saveIf(context, entity, options.output, document);
    context.log("%s: %d ROIs from %d areas in %d bins", ophys.internal.entityName(entity), numel(rois), numel(areas), bins);
    result = struct("rois", numel(rois), "areas", {cellfun(@(p) size(p, 1), rois, UniformOutput=false)});
    if useShape
        result.shapeRois = min(numel(shaped), numel(rois));
    end
end
