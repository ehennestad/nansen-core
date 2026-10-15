function result = roiImages(entity, options, context)
%roiImages dev's ROI classifier images and statistics (computeRoiImages, imageprops, dffprops), for the gallery
%
%   Around each ROI's center (rounded half up) a box of boxSize pixels
%   (odd) is cut from three images: the mean of the frames weighted by the
%   ROI's ΔF/F (normalised to 0..1, then 1 / (1 + exp(-10 (x - 0.5)))), the
%   mean of the frames of its top 1% ΔF/F (at least 50, or all frames when
%   there are fewer; ties in frame order), both less the box's mean over
%   every frame, and the FOV's local correlation image, each scaled to
%   0..255 (dev's AutoAdjust). Outside the image the box is 0. The
%   statistics are the peak ΔF/F, the salience ((ROI - surround + 1) /
%   (surround + 1) of the top 1% image) and the Pearson correlation of each
%   weighted-mean and correlation image with their mean over the ROIs (dev's
%   templateSimilarity). Values are rounded to 4 decimals; null where
%   undefined. As Python's ophys_methods.roi_images.
    stack = ophys.internal.openStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    document = nansen.internal.roisAt(context.Project.load(entity, options.rois), ...
        double(nansen.internal.getField(options, "plane", 1)), double(nansen.internal.getField(options, "channel", 1)));
    rois = ophys.internal.roiList(document);
    dff = double(context.Project.load(entity, options.signals));
    if isvector(dff)
        dff = dff(:);
    end
    if size(dff, 1) ~= frames
        nansen.internal.throwError("invalid-data", "%s has %d frames; the stack has %d", options.signals, size(dff, 1), frames)
    end
    if numel(rois) ~= size(dff, 2)
        rois = rois(cellfun(@(r) ~strcmp(string(nansen.internal.getField(r, "classification", "")), "rejected"), rois));
        if numel(rois) ~= size(dff, 2)
            nansen.internal.throwError("invalid-data", "%s has %d columns, not one per ROI", options.signals, size(dff, 2))
        end
    end
    count = numel(rois);
    boxSize = double(options.boxSize);
    boxSize = boxSize + (mod(boxSize, 2) == 0);   % odd, so the center is a pixel
    half = (boxSize - 1) / 2;
    topCount = floor(frames * 0.01 + 0.5);
    if topCount < 50
        topCount = min(50, frames);
    end
    boxRows = cell(1, count);
    boxColumns = cell(1, count);
    weights = zeros(frames, count);
    tops = false(frames, count);
    for k = 1:count
        center = floor(double(rois{k}.center) + 0.5);
        boxRows{k} = center(1) - half:center(1) + half;   % 0-based
        boxColumns{k} = center(2) - half:center(2) + half;
        d = dff(:, k);
        span = max(d) - min(d);
        normalised = zeros(frames, 1);
        if span > 0
            normalised = (d - min(d)) / span;
        end
        weights(:, k) = 1 ./ (1 + exp(-10 * (normalised - 0.5)));
        [~, order] = sort(-d);   % stable: ties in frame order
        tops(order(1:topCount), k) = true;
    end
    total = zeros(1, count);
    weighted = zeros(boxSize, boxSize, count);
    topped = zeros(boxSize, boxSize, count);
    chunk = 100;   % frames read at a time
    for first = 1:chunk:frames
        last = min(first + chunk - 1, frames);
        data = double(stack.frames(first, last));
        n = last - first + 1;
        for k = 1:count
            [inRows, inColumns] = inside(boxRows{k}, boxColumns{k}, height, width);
            patch = zeros(boxSize, boxSize, n);
            patch(inRows, inColumns, :) = data(boxRows{k}(inRows) + 1, boxColumns{k}(inColumns) + 1, :);
            total(k) = total(k) + sum(patch, "all");
            weighted(:, :, k) = weighted(:, :, k) + reshape(reshape(patch, [], n) * weights(first:last, k), boxSize, boxSize);
            topped(:, :, k) = topped(:, :, k) + sum(patch(:, :, tops(first:last, k)), 3);
        end
    end
    correlation = nansen.internal.localCorrelation(stack);
    images = struct("activityWeightedMean", zeros(boxSize, boxSize, count), "top1Percent", zeros(boxSize, boxSize, count), ...
        "localCorrelation", zeros(boxSize, boxSize, count));
    stats = struct("peakDff", nan(1, count), "salience", nan(1, count), "meanSimilarity", nan(1, count), ...
        "correlationSimilarity", nan(1, count));
    for k = 1:count
        [inRows, inColumns] = inside(boxRows{k}, boxColumns{k}, height, width);
        valid = inRows(:) & inColumns(:)';
        boxMean = total(k) / (nnz(valid) * frames);
        meanImage = weighted(:, :, k) / frames - boxMean * sum(weights(:, k)) / frames;
        meanImage(~valid) = 0;
        topImage = topped(:, :, k) / topCount - boxMean;
        topImage(~valid) = 0;
        correlationImage = zeros(boxSize);
        correlationImage(inRows, inColumns) = correlation(boxRows{k}(inRows) + 1, boxColumns{k}(inColumns) + 1);
        meanImage = autoadjust(meanImage, valid);
        topImage = autoadjust(topImage, valid);
        correlationImage = autoadjust(correlationImage, valid);
        images.activityWeightedMean(:, :, k) = meanImage;
        images.top1Percent(:, :, k) = topImage;
        images.localCorrelation(:, :, k) = correlationImage;
        mask = false(boxSize);
        pixels = double(rois{k}.pixels);
        for p = 1:size(pixels, 1)
            r = pixels(p, 1) - boxRows{k}(1) + 1;
            c = pixels(p, 2) - boxColumns{k}(1) + 1;
            if r >= 1 && r <= boxSize && c >= 1 && c <= boxSize
                mask(r, c) = true;
            end
        end
        outside = valid & ~mask;
        roiMean = NaN;
        surround = NaN;
        if any(mask, "all")
            roiMean = mean(topImage(mask));
        end
        if any(outside, "all")
            surround = mean(topImage(outside));
        end
        stats.peakDff(k) = max(dff(:, k));
        stats.salience(k) = (roiMean - surround + 1) / (surround + 1);
    end
    pairs = {'activityWeightedMean', 'meanSimilarity'; 'localCorrelation', 'correlationSimilarity'};
    for i = 1:2
        stack3 = images.(pairs{i, 1});
        values = nan(1, count);
        if count > 0
            template = mean(stack3, 3);
            for k = 1:count
                values(k) = ophys.internal.pearsonOf(template, stack3(:, :, k));
            end
        end
        stats.(pairs{i, 2}) = values;
    end
    rounded = @(v) floor(v * 1e4 + 0.5) / 1e4;   % NaN and Inf stay, and are written as null
    ids = cellfun(@(r) nansen.internal.getField(r, "id", NaN), rois);
    ids(isnan(ids)) = find(isnan(ids));
    output = struct("boxSize", boxSize, "ids", {num2cell(ids)});
    names = fieldnames(images);
    imageLists = struct();
    for i = 1:numel(names)
        list = cell(1, count);
        for k = 1:count
            list{k} = rounded(reshape(images.(names{i})(:, :, k)', 1, []));   % row after row
        end
        imageLists.(names{i}) = list;
    end
    output.images = imageLists;
    statNames = fieldnames(stats);
    roundedStats = struct();
    for i = 1:numel(statNames)
        values = rounded(stats.(statNames{i}));
        values(~isfinite(values)) = NaN;
        roundedStats.(statNames{i}) = num2cell(values);
    end
    output.stats = roundedStats;
    ophys.internal.saveIf(context, entity, options.output, output);
    context.log("%s: images and statistics of %d ROIs", ophys.internal.entityName(entity), count);
    result = struct("rois", count, "boxSize", boxSize, "stats", roundedStats);
end

function [inRows, inColumns] = inside(rows, columns, height, width)
    inRows = rows >= 0 & rows < height;
    inColumns = columns >= 0 & columns < width;
end

function image = autoadjust(image, valid)
    % Scaled to 0..255 over the box's pixels inside the image, as dev's AutoAdjust; 0 outside, and everywhere when flat
    low = min(image(valid));
    high = max(image(valid));
    if ~(high > low)
        image = zeros(size(image));
        return
    end
    image = (image - low) / (high - low) * 255;
    image(~valid) = 0;
end
