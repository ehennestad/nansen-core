function result = caimanDeconvolution(entity, options, context)
%caimanDeconvolution Spikes and denoised calcium of each trace by CaImAn's deconvolveCa, when it is on the path
%
%   With dev's options (getDeconvolutionParameters, and its CaImAn
%   deconvolution): thresholded OASIS with spikes of at least spikeSnr
%   times the trace's noise (GetSn), the sparsity penalty choose_lambda
%   gives at lambdaPr, and the AR coefficients of tauRise and tauDecay as
%   exp2ar gives them, or estimated from each trace. As Python's
%   caiman_deconvolution, which runs CaImAn's OASIS class.
    if exist("deconvolveCa", "file") ~= 2
        nansen.internal.throwError("dependency-missing", ...
            "ophys.caiman_deconvolution needs CaImAn (deconvolveCa) on the MATLAB path: https://github.com/flatironinstitute/CaImAn-MATLAB")
    end
    traces = double(context.Project.load(entity, options.signals));
    rate = options.frameRate;
    if rate == 0
        rate = entity.get("frame_rate", []);
    end
    if isempty(rate) || ~isnumeric(rate) || isnan(rate) || rate == 0
        nansen.internal.throwError("invalid-options", "give frameRate, or fill in the entity's frame_rate")
    end
    rate = double(rate);
    model = string(options.modelType);
    estimate = logical(options.estimateTimeConstants) || model == "autoar";
    if model == "autoar"   % dev's: AR(2) above 15 Hz, AR(1) else, estimated
        model = "ar1";
        if rate > 15
            model = "ar2";
        end
    end
    decay = exp(-1 / (options.tauDecay * rate));
    rise = exp(-1 / (options.tauRise * rate));
    switch model
        case "ar1"
            pars = decay;
        case "ar2"
            pars = [decay + rise, -decay * rise];   % dev's exp2ar
        otherwise
            pars = [decay, rise];   % exp2: deconvolveCa takes the factors themselves
    end
    if estimate
        pars = [];
    end
    % choose_lambda's kernel: an AR(1) decay of 0.5 s (dev's decay_time), 1000 samples; norminv without the Statistics Toolbox
    kernelNorm = norm(exp(-1 / (rate * 0.5)) .^ (0:999));
    inverse = -sqrt(2) * erfcinv(2 * double(options.lambdaPr));
    [frames, rois] = size(traces);
    spikes = nan(frames, rois);
    calcium = nan(frames, rois);
    for i = 1:rois
        context.checkCancelled();
        if ~any(isnan(traces(:, i)))
            sn = feval("GetSn", traces(:, i));
            % The 'thresholded' route (without optimize_smin) calls oasisAR1/oasisAR2 (or onnls for exp2) directly:
            % CaImAn-MATLAB's foopsi_, constrained_ and thresholded_oasisAR1 share a nested-function bug
            % (update_g's h) that current MATLAB releases refuse to parse
            settings = {char(model), 'thresholded', 'smin', double(options.spikeSnr) * sn, 'lambda', sn * kernelNorm * inverse, 'sn', sn};
            if ~isempty(pars)
                settings = [settings, {'pars', pars}];
            end
            [c, s] = feval("deconvolveCa", traces(:, i), settings{:});
            calcium(:, i) = c(:);
            spikes(:, i) = s(:);
        end
        context.progress(i / max(rois, 1), sprintf("ROI %d/%d", i, rois));
    end
    ophys.internal.saveIf(context, entity, options.output, spikes);
    ophys.internal.saveIf(context, entity, options.denoisedOutput, calcium);
    result = struct("rois", rois, "frames", frames);
end
