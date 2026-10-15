function result = motionCorrection(entity, options, context)
%motionCorrection Align each frame to a reference by the shift of largest (smoothed) phase correlation
%
%   Rigid by default, in whole pixels. With subpixel, the peak is refined to
%   1/20 pixel and frames are moved by bilinear interpolation; with patches
%   > 1, each patch finds its own shift within maxDeviation of the frame's
%   and every pixel moves by the shift interpolated between the patch
%   centres (piecewise rigid), as Python's ophys_methods.motion_correction.
%   The reference is the average of the first referenceFrames frames; each
%   further iteration uses the average of the frames aligned in the one
%   before. The stack is read a chunk at a time and the aligned stack
%   written the same way, so a recording need not fit in memory. In a stack
%   with channels, the shifts are found in the options' channel and every
%   channel is aligned by them; in one with planes, the options' plane is
%   aligned (height x width x channels x frames).
    stack = ophys.internal.openStack(context, entity, options.stack, options);
    whole = context.Project.openStack(entity, options.stack);
    whole.MaxFrames = stack.MaxFrames;
    if ndims(whole) == 5
        target = whole.select(4, double(nansen.internal.getField(options, "plane", 1)));
    elseif ndims(whole) == 4
        target = whole;
    else
        target = [];   % the stack itself
    end
    [height, width, frames] = size(stack);
    flyback = double(nansen.internal.getField(options, "numFlybackLines", 0));
    if flyback >= height - 1
        nansen.internal.throwError("invalid-options", "%d flyback lines leave too little of a frame of %d rows", flyback, height)
    end
    plan = [];
    stretch = string(nansen.internal.getField(options, "stretchCorrection", "none"));
    if stretch == "sciscan"
        zoom = double(nansen.internal.getField(options, "zoomFactor", 0));
        if zoom == 0 && isfield(whole.Metadata, "zoomFactor")
            zoom = whole.Metadata.zoomFactor;
        end
        if zoom == 0
            nansen.internal.throwError("invalid-options", "the recording does not give its zoom factor: set zoomFactor for the stretch correction")
        end
        [displacement, zoom] = ophys.internal.stretchProfile(width, zoom);
        plan = ophys.internal.destretchPlan(displacement);
        width = numel(plan.left);
    elseif stretch ~= "none"
        nansen.internal.throwError("invalid-options", "stretchCorrection is none or sciscan, not '%s'", stretch)
    end
    preparation = ophys.internal.ScanPreparation(stack, flyback, string(nansen.internal.getField(options, "bidirectionalCorrection", "none")), ...
        double(nansen.internal.getField(options, "maxBidirectionalOffset", 10)), plan);
    height = height - flyback;
    subpixel = logical(nansen.internal.getField(options, "subpixel", false));
    patches = double(nansen.internal.getField(options, "patches", 1));
    deviation = double(nansen.internal.getField(options, "maxDeviation", 3));
    if patches > 1 && (floor(height / patches) < 4 || floor(width / patches) < 4)
        nansen.internal.throwError("invalid-options", "%d x %d patches of a %d x %d frame are smaller than 4 pixels", patches, patches, height, width)
    end
    rowEdges = ophys.internal.patchEdges(height, patches);
    columnEdges = ophys.internal.patchEdges(width, patches);
    weights = {ophys.internal.axisWeights(rowEdges, height), ophys.internal.axisWeights(columnEdges, width)};
    tapered = subpixel || patches > 1;   % whole-pixel rigid alignment works on the frames as they are
    count = min(options.referenceFrames, frames);
    reference = mean(double(preparation.prepare(stack.frames(1, count), 1)), 3);
    outputType = string(nansen.internal.getField(options, "outputType", "same"));
    if ~ismember(outputType, ["same", "uint8", "uint16"])
        nansen.internal.throwError("invalid-options", "outputType is same, uint8 or uint16, not '%s'", outputType)
    end
    low = 0;
    high = 0;
    if outputType ~= "same"
        sample = double(preparation.prepare(stack.frames(1, min(ophys.internal.chunk(), frames)), 1));
        saturation = double(nansen.internal.getField(options, "saturation", 0.5));
        low = ophys.internal.percentileOf(sample(:), saturation);
        high = ophys.internal.percentileOf(sample(:), 100 - saturation);
    end
    iterations = options.iterations;
    for iteration = 1:iterations
        last = iteration == iterations;
        shifts = zeros(frames, 2, patches, patches);
        referenceFft = ophys.internal.referenceFft(reference, tapered);
        patchFfts = cell(patches, patches);
        for i = 1:patches
            for j = 1:patches
                patchFfts{i, j} = ophys.internal.referenceFft(reference(rowEdges(i) + 1:rowEdges(i + 1), columnEdges(j) + 1:columnEdges(j + 1)), true);
            end
        end
        total = zeros(height, width);
        if last
            if isempty(target)
                writer = context.Project.stackWriter(entity, options.output, [height, width, frames], outputClass(outputType, stack.ClassName));
            else
                writer = context.Project.stackWriter(entity, options.output, [height, width, target.Size(3:end)], outputClass(outputType, target.ClassName));
            end
        end
        for start = 1:ophys.internal.chunk():frames
            context.checkCancelled();
            stop = min(start + ophys.internal.chunk() - 1, frames);
            chunk = preparation.prepare(stack.frames(start, stop), start);
            if patches == 1
                shifts(start:stop, :, 1, 1) = ophys.internal.estimateShifts(chunk, referenceFft, options.maxShift, subpixel, tapered);
            else
                rigid = ophys.internal.estimateShifts(chunk, referenceFft, options.maxShift, false, true);
                shifts(start:stop, :, :, :) = ophys.internal.estimatePatchShifts(chunk, patchFfts, rowEdges, columnEdges, rigid, ...
                    options.maxShift, deviation, subpixel);
            end
            here = shifts(start:stop, :, :, :);
            if last
                if isempty(target)
                    writer.write(start, ophys.internal.recastFrames(ophys.internal.alignFrames(chunk, here, weights, subpixel), outputType, low, high));
                else
                    channels = preparation.prepare(target.frames(start, stop), start);
                    aligned = zeros(size(channels, 1:4), "like", channels);
                    for c = 1:size(channels, 3)
                        aligned(:, :, c, :) = reshape(ophys.internal.alignFrames(reshape(channels(:, :, c, :), height, width, []), ...
                            here, weights, subpixel), height, width, 1, []);
                    end
                    writer.write(start, ophys.internal.recastFrames(aligned, outputType, low, high));
                end
            else
                total = total + sum(double(ophys.internal.alignFrames(chunk, here, weights, subpixel)), 3);
            end
            context.progress(((iteration - 1) * frames + stop) / (iterations * frames), ...
                sprintf("iteration %d: frame %d/%d", iteration, stop, frames));
        end
        if last
            writer.close();
        end
        reference = total / frames;
    end
    if patches == 1
        saved = shifts(:, :, 1, 1);
    else
        saved = zeros(frames, 2, patches * patches);   % patch (i, j) at i * patches + j, from 0
        for i = 1:patches
            for j = 1:patches
                saved(:, :, (i - 1) * patches + j) = shifts(:, :, i, j);
            end
        end
    end
    if ~subpixel
        saved = int32(saved);
    end
    ophys.internal.saveIf(context, entity, options.shiftsOutput, saved);
    distance = sqrt(shifts(:, 1, :, :) .^ 2 + shifts(:, 2, :, :) .^ 2);
    largest = max([0; abs(shifts(:))]);
    if subpixel   % found to 1/20 of a pixel, and good to about a tenth
        largest = ophys.internal.roundTo(largest, 1);
        meanShift = ophys.internal.roundTo(mean(distance, "all"), 1);
    else
        meanShift = ophys.internal.roundTo(mean(distance, "all"), 4);
    end
    context.log("%s: largest shift %g px", ophys.internal.entityName(entity), largest);
    result = struct("frames", frames, "maxShift", largest, "meanShift", meanShift);
    if preparation.Mode ~= "none"
        result.bidirectionalOffset = preparation.offset(1);
    end
    if ~isempty(plan)
        result.stretchZoom = zoom;
    end
end

function className = outputClass(outputType, className)
    if outputType ~= "same"
        className = outputType;
    end
end
