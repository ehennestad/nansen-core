function result = extract(entity, options, context)
%extract Detect cells with EXTRACT, when it is on the path, and save them as ROIs with their traces
%
%   The options are EXTRACT's avg_cell_radius, thresholds.T_min_snr,
%   trace_output_option, cellfind_min_snr, max_iter,
%   spatial_highpass_cutoff, temporal_denoising, dendrite_aware and
%   num_partitions_x and num_partitions_y (left to EXTRACT when either is 0).
    if exist("extractor", "file") ~= 2 || exist("get_defaults", "file") ~= 2
        nansen.internal.throwError("dependency-missing", ...
            "ophys.extract needs EXTRACT on the MATLAB path: https://github.com/schnitzer-lab/EXTRACT-public")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    config = struct("avg_cell_radius", options.cellRadius, "use_sparse_arrays", 0, "verbose", 1, ...
        "use_gpu", ophys.internal.extractGpu(), ...
        "trace_output_option", char(string(nansen.internal.getField(options, "traceOutputOption", "baseline_adjusted"))), ...
        "cellfind_min_snr", double(nansen.internal.getField(options, "cellfindMinSnr", 1)), ...
        "max_iter", double(nansen.internal.getField(options, "maxIterations", 6)), ...
        "spatial_highpass_cutoff", double(nansen.internal.getField(options, "spatialHighpassCutoff", 5)), ...
        "temporal_denoising", logical(nansen.internal.getField(options, "temporalDenoising", false)), ...
        "dendrite_aware", logical(nansen.internal.getField(options, "dendriteAware", false)), ...
        "thresholds", struct("T_min_snr", double(options.minSnr)));
    partitions = [double(nansen.internal.getField(options, "partitionsX", 1)), ...
        double(nansen.internal.getField(options, "partitionsY", 1))];
    if all(partitions > 0)   % else EXTRACT chooses
        config.num_partitions_x = partitions(1);
        config.num_partitions_y = partitions(2);
    end
    config = feval("get_defaults", config);
    context.log("%s: running EXTRACT on %d frames", ophys.internal.entityName(entity), frames);
    output = feval("extractor", single(stack), config);
    context.log("%s: EXTRACT kept %d cells", ophys.internal.entityName(entity), size(output.spatial_weights, 3));
    weights = full(double(output.spatial_weights));
    rois = {};
    kept = [];
    for i = 1:size(weights, 3)
        cell_ = weights(:, :, i);
        [peak, at] = max(cell_, [], "all");
        if peak <= 0
            continue
        end
        % the 8-connected area around the peak, as dev's enforceSingleSegment: a cell's weights can have
        % faint patches elsewhere that would move its centre
        [peakRow, peakColumn] = ind2sub([height, width], at);
        areas = ophys.internal.components(cell_ >= options.threshold * peak, 8);
        for k = 1:numel(areas)
            if any(areas{k}(:, 1) == peakRow & areas{k}(:, 2) == peakColumn)
                rois{end + 1} = ophys.internal.makeRoi(numel(rois) + 1, sortrows(areas{k})); %#ok<AGROW>
                kept(end + 1) = i; %#ok<AGROW>
                break
            end
        end
    end
    context.Project.save(entity, options.rois, struct("imageSize", [height, width], "rois", {rois}));
    ophys.internal.saveIf(context, entity, options.output, double(output.temporal_weights(:, kept)));
    result = struct("rois", numel(rois), "frames", frames);
end
