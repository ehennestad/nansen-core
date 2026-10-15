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
%   aligned (height x width x channels x frames), or with plane 0 every
%   plane, each by its own reference and shifts, one plane after the other
%   in each chunk (height x width x channels x planes x frames; the planes'
%   shifts joined along their last dimension). Only the frames
%   firstFrame..lastFrame are aligned and written. A run that stopped goes
%   on where it stopped, to the same result (nansen.Checkpoint).
    [whole, stacks, every] = ophys.internal.planeStacks(context, entity, options.stack, options);
    [height, width, frames] = size(stacks{1});
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
    mode = string(nansen.internal.getField(options, "bidirectionalCorrection", "none"));
    count = numel(stacks);
    preparations = cell(1, count);
    for p = 1:count
        preparations{p} = ophys.internal.ScanPreparation(stacks{p}, flyback, mode, ...
            double(nansen.internal.getField(options, "maxBidirectionalOffset", 10)), plan);
    end
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
    referenceCount = min(options.referenceFrames, frames);
    outputType = string(nansen.internal.getField(options, "outputType", "same"));
    if ~ismember(outputType, ["same", "uint8", "uint16"])
        nansen.internal.throwError("invalid-options", "outputType is same, uint8 or uint16, not '%s'", outputType)
    end
    % each plane aligned: its stack, the frames written (with every channel; empty: the stack itself), preparation,
    % reference and the limits its frames are recast between
    planes = cell(1, count);
    for p = 1:count
        stack = stacks{p};
        preparation = preparations{p};
        target = [];
        if ndims(whole) == 5
            index = double(nansen.internal.getField(options, "plane", 1));
            if every
                index = p;
            end
            target = whole.select(4, index);
        elseif ndims(whole) == 4
            target = whole;
        end
        plane = struct();
        plane.stack = stack;
        plane.target = target;
        plane.preparation = preparation;
        plane.reference = mean(double(preparation.prepare(stack.frames(1, referenceCount), 1)), 3);
        plane.low = 0;
        plane.high = 0;
        if outputType ~= "same"
            sample = double(preparation.prepare(stack.frames(1, min(ophys.internal.chunk(), frames)), 1));
            saturation = double(nansen.internal.getField(options, "saturation", 0.5));
            plane.low = ophys.internal.percentileOf(sample(:), saturation);
            plane.high = ophys.internal.percentileOf(sample(:), 100 - saturation);
        end
        planes{p} = plane;
    end
    iterations = options.iterations;
    first = planes{1};
    if isempty(first.target)
        dimensions = [height, width, frames];
        className = outputClass(outputType, first.stack.ClassName);
    elseif every
        dimensions = [height, width, first.target.Size(3:end - 1), count, frames];
        className = outputClass(outputType, first.target.ClassName);
    else
        dimensions = [height, width, first.target.Size(3:end)];
        className = outputClass(outputType, first.target.ClassName);
    end
    % a run that stopped goes on where it stopped: from its iteration's references and what it had found
    % (nansen.Checkpoint); each plane's state on the last dimension (height x width x planes, frames x 2 x patches x patches x planes)
    checkpoint = context.Project.checkpoint(entity, options.output, dimensions, className, options, whole, ...
        Passes=iterations, Method=context.Method);
    if checkpoint.Resumed
        references = reshape(checkpoint.State.reference, height, width, count);
        for p = 1:count
            planes{p}.reference = references(:, :, p);
        end
        context.log("%s: going on from frame %d of iteration %d", ophys.internal.entityName(entity), checkpoint.FramesDone, checkpoint.PassNumber);
    end
    for iteration = checkpoint.PassNumber:iterations
        last = iteration == iterations;
        firstFrame = checkpoint.firstFrame(iteration);
        for p = 1:count
            reference = planes{p}.reference;
            planes{p}.shifts = zeros(frames, 2, patches, patches);
            planes{p}.referenceFft = ophys.internal.referenceFft(reference, tapered);
            patchFfts = cell(patches, patches);
            for i = 1:patches
                for j = 1:patches
                    patchFfts{i, j} = ophys.internal.referenceFft(reference(rowEdges(i) + 1:rowEdges(i + 1), columnEdges(j) + 1:columnEdges(j + 1)), true);
                end
            end
            planes{p}.patchFfts = patchFfts;
            planes{p}.total = zeros(height, width);
            if firstFrame > 1 && last
                kept = reshape(checkpoint.State.shifts, firstFrame - 1, 2, patches, patches, count);
                planes{p}.shifts(1:firstFrame - 1, :, :, :) = kept(:, :, :, :, p);
            elseif firstFrame > 1
                totals = reshape(checkpoint.State.total, height, width, count);
                planes{p}.total = totals(:, :, p);
            end
        end
        references = zeros(height, width, count);
        for p = 1:count
            references(:, :, p) = planes{p}.reference;
        end
        if last
            writer = checkpoint.writer();
        end
        for start = firstFrame:ophys.internal.chunk():frames
            context.checkCancelled();
            stop = min(start + ophys.internal.chunk() - 1, frames);
            aligned = cell(1, count);
            for p = 1:count
                plane = planes{p};
                chunk = plane.preparation.prepare(plane.stack.frames(start, stop), start);
                if patches == 1
                    planes{p}.shifts(start:stop, :, 1, 1) = ophys.internal.estimateShifts(chunk, plane.referenceFft, options.maxShift, subpixel, tapered);
                else
                    rigid = ophys.internal.estimateShifts(chunk, plane.referenceFft, options.maxShift, false, true);
                    planes{p}.shifts(start:stop, :, :, :) = ophys.internal.estimatePatchShifts(chunk, plane.patchFfts, rowEdges, columnEdges, rigid, ...
                        options.maxShift, deviation, subpixel);
                end
                here = planes{p}.shifts(start:stop, :, :, :);
                if ~last
                    planes{p}.total = planes{p}.total + sum(double(ophys.internal.alignFrames(chunk, here, weights, subpixel)), 3);
                elseif isempty(plane.target)
                    aligned{p} = ophys.internal.recastFrames(ophys.internal.alignFrames(chunk, here, weights, subpixel), outputType, plane.low, plane.high);
                else
                    channels = plane.preparation.prepare(plane.target.frames(start, stop), start);
                    moved = zeros(size(channels, 1:4), "like", channels);
                    for c = 1:size(channels, 3)
                        moved(:, :, c, :) = reshape(ophys.internal.alignFrames(reshape(channels(:, :, c, :), height, width, []), ...
                            here, weights, subpixel), height, width, 1, []);
                    end
                    aligned{p} = ophys.internal.recastFrames(moved, outputType, plane.low, plane.high);
                end
            end
            if last && every
                n = stop - start + 1;
                channelCount = size(aligned{1}, 3);
                joined = zeros([height, width, channelCount, count, n], "like", aligned{1});
                for p = 1:count
                    joined(:, :, :, p, :) = reshape(aligned{p}, height, width, channelCount, 1, n);
                end
                writer.write(start, joined);
            elseif last
                writer.write(start, aligned{1});
            end
            if last
                found = zeros(stop, 2, patches, patches, count);
                for p = 1:count
                    found(:, :, :, :, p) = planes{p}.shifts(1:stop, :, :, :);
                end
                checkpoint.save(iteration, stop, struct("reference", references, "shifts", found));
            else
                totals = zeros(height, width, count);
                for p = 1:count
                    totals(:, :, p) = planes{p}.total;
                end
                checkpoint.save(iteration, stop, struct("reference", references, "total", totals));
            end
            context.progress(((iteration - 1) * frames + stop) / (iterations * frames), ...
                sprintf("iteration %d: frame %d/%d", iteration, stop, frames));
        end
        if last
            writer.close();
        end
        for p = 1:count
            planes{p}.reference = planes{p}.total / frames;
        end
    end
    saved = cell(1, count);
    found = cell(1, count);
    everyShift = zeros(frames, 2, patches, patches, count);
    for p = 1:count
        shifts = planes{p}.shifts;
        everyShift(:, :, :, :, p) = shifts;
        if patches == 1
            kept = shifts(:, :, 1, 1);
        else
            kept = zeros(frames, 2, patches * patches);   % patch (i, j) at i * patches + j, from 0
            for i = 1:patches
                for j = 1:patches
                    kept(:, :, (i - 1) * patches + j) = shifts(:, :, i, j);
                end
            end
        end
        if ~subpixel
            kept = int32(kept);
        end
        saved{p} = kept;
        found{p} = shiftSummary(shifts, subpixel);
        if mode ~= "none"
            found{p}.bidirectionalOffset = planes{p}.preparation.offset(1);
        end
    end
    if every
        ophys.internal.saveIf(context, entity, options.shiftsOutput, cat(2 + (patches > 1), saved{:}));
        checkpoint.finish();
        summary = shiftSummary(everyShift, subpixel);
        result = struct("frames", frames, "maxShift", summary.maxShift, "meanShift", summary.meanShift);
        perPlane = cell(1, count);
        for p = 1:count
            perPlane{p} = struct("plane", p, "maxShift", found{p}.maxShift, "meanShift", found{p}.meanShift);
            if isfield(found{p}, "bidirectionalOffset")
                perPlane{p}.bidirectionalOffset = found{p}.bidirectionalOffset;
            end
        end
        result.planes = perPlane;
    else
        ophys.internal.saveIf(context, entity, options.shiftsOutput, saved{1});
        checkpoint.finish();
        result = struct("frames", frames, "maxShift", found{1}.maxShift, "meanShift", found{1}.meanShift);
        if isfield(found{1}, "bidirectionalOffset")
            result.bidirectionalOffset = found{1}.bidirectionalOffset;
        end
    end
    context.log("%s: largest shift %g px", ophys.internal.entityName(entity), result.maxShift);
    if ~isempty(plan)
        result.stretchZoom = zoom;
    end
end

function summary = shiftSummary(shifts, subpixel)
    % The largest shift and the mean distance moved of shifts (frames x 2 x patches x patches (x planes)), rounded as
    % the method returns them
    distance = sqrt(shifts(:, 1, :, :, :) .^ 2 + shifts(:, 2, :, :, :) .^ 2);
    largest = max([0; abs(shifts(:))]);
    if subpixel   % found to 1/20 of a pixel, and good to about a tenth
        summary = struct("maxShift", ophys.internal.roundTo(largest, 1), "meanShift", ophys.internal.roundTo(mean(distance, "all"), 1));
    else
        summary = struct("maxShift", largest, "meanShift", ophys.internal.roundTo(mean(distance, "all"), 4));
    end
end

function className = outputClass(outputType, className)
    if outputType ~= "same"
        className = outputType;
    end
end
