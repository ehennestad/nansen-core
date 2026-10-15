function result = cnmf(entity, options, context)
%cnmf Cells found by CaImAn-MATLAB's CNMF on the whole stack, saved as ROIs with their traces
%
%   As CaImAn-MATLAB's demo_script: preprocess_data, initialize_components
%   (greedy), update_spatial_components, update_temporal_components,
%   merge_components and an update of both again. Each footprint's ROI is
%   the 8-connected pixels around its peak above threshold times it; the
%   traces (C + YrA) are saved as signals and C as the denoised calcium.
%   Python's ophys_methods.cnmf runs CaImAn's CNMF the same way.
    needed = ["CNMFSetParms", "preprocess_data", "initialize_components", "update_spatial_components", ...
        "update_temporal_components", "merge_components"];
    if ~all(arrayfun(@(name) exist(name, "file") == 2, needed))
        nansen.internal.throwError("dependency-missing", ...
            "ophys.cnmf needs CaImAn-MATLAB on the MATLAB path: https://github.com/flatironinstitute/CaImAn-MATLAB")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    rate = double(options.frameRate);
    if rate <= 0
        rate = double(entity.get("frame_rate", 30));
        if ~(isnumeric(rate) && isscalar(rate) && rate > 0)
            rate = 30;
        end
    end
    radius = double(options.cellRadius);
    parameters = feval("CNMFSetParms", 'd1', height, 'd2', width, 'p', 1, 'gSig', radius, ...
        'merge_thr', double(options.mergeThreshold), 'nb', 1, 'fr', rate);   % char names: CaImAn-MATLAB checks them as OPTIMSET does
    Y = double(stack);
    [P, Y] = feval("preprocess_data", Y, 1);
    context.log("%s: running CNMF on %d frames", ophys.internal.entityName(entity), frames);
    [Ain, Cin, bin, fin] = feval("initialize_components", Y, double(options.components), radius, parameters, P);
    Yr = reshape(Y, height * width, frames);
    [A, b, Cin] = feval("update_spatial_components", Yr, Cin, fin, [Ain, bin], P, parameters);
    P.p = 0;
    [C, f, P, S] = feval("update_temporal_components", Yr, A, b, Cin, fin, P, parameters);
    [A, C, ~, ~, P] = feval("merge_components", Yr, A, b, C, f, P, S, parameters);
    P.p = 1;
    [A, b, C] = feval("update_spatial_components", Yr, C, f, [A, b], P, parameters);
    [C, ~, ~, ~, YrA] = feval("update_temporal_components", Yr, A, b, C, f, P, parameters);
    A = full(A);
    rois = {};
    kept = [];
    for k = 1:size(A, 2)
        weights = reshape(A(:, k), height, width);
        [peak, at] = max(weights, [], "all");
        if peak <= 0
            continue
        end
        [peakRow, peakColumn] = ind2sub([height, width], at);
        areas = ophys.internal.components(weights >= options.threshold * peak, 8);
        for j = 1:numel(areas)
            if any(areas{j}(:, 1) == peakRow & areas{j}(:, 2) == peakColumn)
                rois{end + 1} = ophys.internal.makeRoi(numel(rois) + 1, sortrows(areas{j})); %#ok<AGROW>
                kept(end + 1) = k; %#ok<AGROW>
                break
            end
        end
    end
    context.Project.save(entity, options.rois, struct("imageSize", [height, width], "rois", {rois}));
    calcium = full(C(kept, :))';
    ophys.internal.saveIf(context, entity, options.output, calcium + full(YrA(kept, :))');
    ophys.internal.saveIf(context, entity, options.denoisedOutput, calcium);
    context.log("%s: CNMF kept %d cells", ophys.internal.entityName(entity), numel(rois));
    result = struct("rois", numel(rois), "frames", frames);
end
