function result = caimanDeconvolution(entity, options, context)
%caimanDeconvolution Spikes and denoised calcium of each trace by CaImAn's deconvolveCa, when it is on the path
    if exist("deconvolveCa", "file") ~= 2
        nansen.internal.throwError("dependency-missing", ...
            "ophys.caiman_deconvolution needs CaImAn (deconvolveCa) on the MATLAB path: https://github.com/flatironinstitute/CaImAn-MATLAB")
    end
    traces = double(context.Project.load(entity, options.signals));
    [frames, rois] = size(traces);
    spikes = nan(frames, rois);
    calcium = nan(frames, rois);
    model = "ar" + options.order;
    for i = 1:rois
        context.checkCancelled();
        if ~any(isnan(traces(:, i)))
            % OASIS with the kernel estimated and the given sparsity penalty. The 'thresholded' route with smin 0
            % calls oasisAR1/oasisAR2 directly: CaImAn-MATLAB's foopsi_, constrained_ and thresholded_oasisAR1
            % share a nested-function bug (update_g's h) that current MATLAB releases refuse to parse
            [c, s] = feval("deconvolveCa", traces(:, i), char(model), 'thresholded', 'smin', 0, 'lambda', double(options.lambda));
            calcium(:, i) = c(:);
            spikes(:, i) = s(:);
        end
        context.progress(i / max(rois, 1), sprintf("ROI %d/%d", i, rois));
    end
    ophys.internal.saveIf(context, entity, options.output, spikes);
    ophys.internal.saveIf(context, entity, options.denoisedOutput, calcium);
    result = struct("rois", rois, "frames", frames);
end
