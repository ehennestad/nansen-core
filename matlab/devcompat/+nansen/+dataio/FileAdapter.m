classdef (Abstract) FileAdapter < handle & matlab.mixin.CustomDisplay
%FileAdapter dev's nansen.dataio.FileAdapter, the base class of dev's class file adapters
%
%   nansen.legacy.FileAdapterShim makes dev's file adapter classes, imported
%   unchanged, read and write here: obj = Adapter(filename) and
%   obj.load(), or obj = Adapter(filename, '-w') and obj.save(data). This is
%   dev's base class less what needs the rest of dev (writing its metadata
%   files, which Metadata reads, nansen.internal.parseDevYaml; uigetfile
%   dialogs and .npy conversion): the same abstract properties
%   (DataType, SUPPORTED_FILE_TYPES) and readData, the same Filename, Name,
%   FileType, Writable, load, save, writeData (which refuses, unless the
%   subclass writes) and writeDataToMat, so a subclass's readData and
%   writeData run as they did in dev.
%
%   dev's own adapter classes, which a project's adapters may subclass
%   (nansen.dataio.fileadapter.imagestack.ImageStack, ...roi.RoiGroup,
%   ...timeseries.RoiSignalArray, ...), are in matlab/devcompat too, with
%   dev's constants: they read and write with CoreAdapter, the adapter here
%   of the file's type (readWithCoreAdapter, writeWithCoreAdapter), which
%   the shim sets from legacyFileAdapter.builtIn.

    properties (Dependent)
        Filename char
        Metadata
        Name char
    end

    properties (Abstract, Constant)
        DataType
    end

    properties
        Writable = false;   % Does the file adapter have write permission?
    end

    properties (Hidden)
        % The adapter here that reads and writes the file in place of one of
        % dev's own adapter classes (its ImageStack, RoiGroup, ...), which
        % nansen.legacy.FileAdapterShim gives from legacyFileAdapter.builtIn
        CoreAdapter = []
    end

    properties (SetAccess = private, Hidden)
        DiscardConvertedMatfile = false
        RedoFileConversion = false
    end

    properties (Access = protected)
        FileSelectionMode = 'single';
    end

    properties (Abstract, Constant, Hidden, Access = protected)
        SUPPORTED_FILE_TYPES cell
    end

    properties (Dependent, Access = protected)
        FileType % The file type as described by the file extension
    end

    properties (Access = private)
        Filename_
    end

    methods (Abstract, Access = protected)
        data = readData(obj, varargin)
    end

    methods (Static, Access = protected)
        function S = getDefaultMetadata()
            %getDefaultMetadata Default metadata of the class; subclasses may override
            S = struct();
        end

        function tf = isName(value)
            %isName Whether a value is the name of a variable (of a .mat file)
            tf = (ischar(value) && isrow(value) && isvarname(value)) || (isstring(value) && isscalar(value) && isvarname(char(value)));
        end
    end

    methods
        function obj = FileAdapter(varargin)
            %FileAdapter obj = Adapter(filename), or Adapter(filename, '-w') (or 'writable') to write
            if isempty(varargin)
                return
            end
            flags = varargin(cellfun(@(c) ischar(c) || (isstring(c) && isscalar(c)), varargin));
            flags = cellfun(@char, flags, UniformOutput=false);
            obj.Writable = any(ismember({'-w', 'writable'}, flags));
            obj.DiscardConvertedMatfile = ismember('-tempmat', flags);
            obj.RedoFileConversion = ismember('-u', flags);
            try
                obj.Filename = char(varargin{1});
            catch err
                warning(err.identifier, '%s', err.message)
            end
        end

        function data = load(obj, varargin)
            obj.validateFilepath('load');
            data = obj.readData(varargin{:});
        end

        function save(obj, data, varargin)
            obj.assertIsWritable()
            obj.validateFilepath('save');
            obj.writeData(data, varargin{:})
        end

        function setMetadata(obj, name, value, groupName) %#ok<INUSD>
            error('NANSEN:FileAdapter:NoMetadata', ...
                'dev''s metadata files of file adapters are not kept here (%s)', builtin('class', obj))
        end

        function fileTypes = getFileTypes(obj)
            fileTypes = obj.SUPPORTED_FILE_TYPES;
        end

        function open(obj)
            error('View is not implemented for file adapter "%s"', builtin('class', obj))
        end

        function view(obj)
            error('View is not implemented for file adapter "%s"', builtin('class', obj))
        end
    end

    methods % Set/get methods
        function set.Filename(obj, newValue)
            if ~isempty(obj.Filename_) && ~isequal(obj.Filename_, newValue)
                error('Filename is already set for this FileAdapter')
            elseif isequal(obj.Filename_, newValue)
                return
            end
            assert(ischar(newValue), 'Nansen:FileIO:InvalidInput', 'Filename must be a character vector')
            [~, filename, ext] = fileparts(newValue);
            assert(~isempty(filename) && ~isempty(ext), 'Nansen:FileIO:InvalidFilename', 'Filename must be a valid filename')
            obj.Filename_ = newValue;
        end

        function filename = get.Filename(obj)
            filename = obj.Filename_;
        end

        function name = get.Name(obj)
            [~, name, ~] = fileparts(obj.Filename);
        end

        function fileType = get.FileType(obj)
            [~, ~, fileExt] = fileparts(obj.Filename);
            fileType = strrep(fileExt, '.', '');
        end

        function metadata = get.Metadata(obj)
            % dev's metadata file beside the data (<name>.yaml, else <name>.yaml.txt), as dev's adapter read it
            % (its File, Data and Custom groups); the adapter's default metadata when there is none, or it is not read
            metadata = obj.getDefaultMetadata();
            if isempty(obj.Filename)
                return
            end
            [folder, name] = fileparts(string(obj.Filename));
            candidates = [fullfile(folder, name + ".yaml"), fullfile(folder, name + ".yaml.txt")];
            found = candidates(isfile(candidates));
            if isempty(found)
                return
            end
            try
                document = nansen.internal.parseDevYaml(nansen.internal.readText(found(1)));
            catch err
                if ~isa(err, "nansen.NansenError")
                    rethrow(err)
                end
                return
            end
            if isstruct(document) && isscalar(document)
                metadata = document;
            end
        end
    end

    methods (Access = protected)
        function writeData(obj, data, varargin) %#ok<INUSD> Subclass can override
            name = strsplit(builtin('class', obj), '.');
            error('The file adapter "%s" does not support saving of data to file.', name{end})
        end

        function writeDataToMat(obj, S, varargin) %#ok<INUSD>
            %writeDataToMat Write the fields of a struct to the file, as variables of a .mat file (v7.3 when large)
            info = whos('S');
            if info.bytes > 2^31
                versionFlag = '-v7.3';
            else
                versionFlag = '-v7';
            end
            if isfile(obj.Filename)
                save(obj.Filename, '-struct', 'S', '-append', versionFlag)
            else
                save(obj.Filename, '-struct', 'S', versionFlag)
            end
        end

        function data = readWithCoreAdapter(obj, varargin)
            %readWithCoreAdapter What dev's own adapter classes read, here: the file read by the adapter here of its type
            %
            %   With the name of a variable, the variable of that name when
            %   the file reads as a struct of them (a .mat file), as dev's
            %   adapters of .mat files read one by name.
            if isempty(obj.CoreAdapter)
                error('NANSEN:FileAdapter:NoCoreAdapter', ...
                    'nansen-core has no file adapter that reads the .%s files of dev''s %s', obj.FileType, obj.devBase())
            end
            data = obj.CoreAdapter.read(obj.Filename);
            if ~isempty(varargin) && obj.isName(varargin{1}) && isstruct(data) && isscalar(data) && isfield(data, char(varargin{1}))
                data = data.(char(varargin{1}));
            end
        end

        function writeWithCoreAdapter(obj, data, varargin)
            %writeWithCoreAdapter What dev's own adapter classes write, here: written by the adapter here of the file's type
            %
            %   With the name of a variable, a .mat file gets that variable,
            %   and keeps its others, as dev's adapters of .mat files wrote
            %   one by name.
            if ~isempty(varargin) && obj.isName(varargin{1}) && strcmpi(obj.FileType, 'mat')
                obj.writeDataToMat(struct(char(varargin{1}), {data}))
                return
            end
            if isempty(obj.CoreAdapter)
                error('NANSEN:FileAdapter:NoCoreAdapter', ...
                    'nansen-core has no file adapter that writes the .%s files of dev''s %s', obj.FileType, obj.devBase())
            end
            obj.CoreAdapter.write(obj.Filename, data);
        end

        function name = devBase(obj)
            %devBase The name of the class of dev's this one is or is built on: the one whose package is dev's
            name = builtin('class', obj);
            for candidate = reshape(superclasses(obj), 1, [])
                if startsWith(candidate{1}, 'nansen.') && ~strcmp(candidate{1}, 'nansen.dataio.FileAdapter')
                    name = candidate{1};
                    return
                end
            end
        end

        function assertIsWritable(obj)
            assert(obj.Writable, 'This file adapter does not have write permission')
        end

        function validateFilepath(obj, action)
            if isempty(obj.Filename)
                error('Nansen:FileIO:FilenameMissing', 'Can not %s data because Filename is not set.', action)
            end
            if strcmp(action, 'load') && ~isfile(obj.Filename) && ~exist(obj.Filename, 'file')
                error('Nansen:FileIO:FilenameDoesNotExist', 'Can not %s data because file does not exist.', action)
            end
        end

        function fileFilter = getFileFilter(obj)
            fileFilter = strcat('*.', obj.SUPPORTED_FILE_TYPES);
            if isrow(fileFilter)
                fileFilter = fileFilter';
            end
        end
    end

    methods (Hidden)
        function className = classname(obj)
            className = strsplit(builtin('class', obj), '.');
            className = className{end};
        end
    end
end
