require 'torch'
require 'nn'
require 'image'
require 'optim'

require 'loadcaffe'

--------------------------------------------------------------------------------
function stylize(params)

    updateProgress(string.format("Style image is %s", params.style_image))
    updateProgress(string.format("Content image is %s", params.content_image))
    updateProgress(string.format("Number of iterations are %d", params.num_iterations))

    if params.gpu >= 0 then
        if params.backend ~= 'clnn' then
            require 'cutorch'
            require 'cunn'
            cutorch.setDevice(params.gpu + 1)
        else
            require 'clnn'
            require 'cltorch'
            cltorch.setDevice(params.gpu + 1)
        end
    else
        params.backend = 'nn'
    end

    if params.backend == 'cudnn' then
        require 'cudnn'
        if params.cudnn_autotune then
            cudnn.benchmark = true
        end
        cudnn.SpatialConvolution.accGradParameters = nn.SpatialConvolutionMM.accGradParameters -- ie: nop
    end


    updateProgress(string.format("Proto model is %s", params.model_file))
    updateProgress(string.format("Proto file is %s", params.proto_file))

    local loadcaffe_backend = params.backend
    updateProgress("Attempting to load model")
    if params.backend == 'clnn' then loadcaffe_backend = 'nn' end
    local cnn = loadcaffe.load(params.proto_file, params.model_file, loadcaffe_backend):float()
    updateProgress("Model loaded")
    if params.gpu >= 0 then
        if params.backend ~= 'clnn' then
            cnn:cuda()
        else
            cnn:cl()
        end
    end

    local content_image = image.load(params.content_image, 3)
    content_image = image.scale(content_image, params.image_size, 'bilinear')
    local content_image_caffe = preprocess(content_image):float()


    local style_size = math.ceil(params.style_scale * params.image_size)
    local style_image_list = params.style_image:split(',')
    local style_images_caffe = {}
    for _, img_path in ipairs(style_image_list) do
        local img = image.load(img_path, 3)
        img = image.scale(img, style_size, 'bilinear')
        local img_caffe = preprocess(img):float()
        table.insert(style_images_caffe, img_caffe)
    end

    -- Handle style blending weights for multiple style inputs
    local style_blend_weights = nil
    if params.style_blend_weights == 'nil' then
        -- Style blending not specified, so use equal weighting
        style_blend_weights = {}
        for i = 1, #style_image_list do
            table.insert(style_blend_weights, 1.0)
        end
    else
        style_blend_weights = params.style_blend_weights:split(',')
        assert(#style_blend_weights == #style_image_list,
            '-style_blend_weights and -style_images must have the same number of elements')
    end

    -- Normalize the style blending weights so they sum to 1
    local style_blend_sum = 0
    for i = 1, #style_blend_weights do
        style_blend_weights[i] = tonumber(style_blend_weights[i])
        style_blend_sum = style_blend_sum + style_blend_weights[i]
    end
    for i = 1, #style_blend_weights do
        style_blend_weights[i] = style_blend_weights[i] / style_blend_sum
    end

    if params.gpu >= 0 then
        if params.backend ~= 'clnn' then
            content_image_caffe = content_image_caffe:cuda()
            for i = 1, #style_images_caffe do
                style_images_caffe[i] = style_images_caffe[i]:cuda()
            end
        else
            content_image_caffe = content_image_caffe:cl()
            for i = 1, #style_images_caffe do
                style_images_caffe[i] = style_images_caffe[i]:cl()
            end
        end
    end

    local content_layers = params.content_layers:split(",")
    local style_layers = params.style_layers:split(",")

    -- Set up the network, inserting style and content loss modules
    local content_losses, style_losses = {}, {}
    local next_content_idx, next_style_idx = 1, 1
    local net = nn.Sequential()
    if params.tv_weight > 0 then
        local tv_mod = nn.TVLoss(params.tv_weight):float()
        if params.gpu >= 0 then
            if params.backend ~= 'clnn' then
                tv_mod:cuda()
            else
                tv_mod:cl()
            end
        end
        net:add(tv_mod)
    end

    for i = 1, #cnn.modules do
        if next_content_idx <= #content_layers or next_style_idx <= #style_layers then
            local layer = cnn:get(i)
            local name = layer.name
            local layer_type = torch.type(layer)
            local is_pooling = (layer_type == 'cudnn.SpatialMaxPooling' or layer_type == 'nn.SpatialMaxPooling')
            if is_pooling and params.pooling == 'avg' then
                assert(layer.padW == 0 and layer.padH == 0)
                local kW, kH = layer.kW, layer.kH
                local dW, dH = layer.dW, layer.dH
                local avg_pool_layer = nn.SpatialAveragePooling(kW, kH, dW, dH):float()
                if params.gpu >= 0 then
                    if params.backend ~= 'clnn' then
                        avg_pool_layer:cuda()
                    else
                        avg_pool_layer:cl()
                    end
                end
                local msg = 'Replacing max pooling at layer %d with average pooling'
                updateProgress(string.format(msg, i))
                net:add(avg_pool_layer)
            else
                net:add(layer)
            end
            if name == content_layers[next_content_idx] then
                updateProgress(string.format("Setting up content layer %d : %s", i, layer.name))
                local target = net:forward(content_image_caffe):clone()
                local norm = params.normalize_gradients
                local loss_module = nn.ContentLoss(params.content_weight, target, norm):float()
                if params.gpu >= 0 then
                    if params.backend ~= 'clnn' then
                        loss_module:cuda()
                    else
                        loss_module:cl()
                    end
                end
                net:add(loss_module)
                table.insert(content_losses, loss_module)
                next_content_idx = next_content_idx + 1
            end
            if name == style_layers[next_style_idx] then
                updateProgress(string.format("Setting up style layer %d : %s", i, layer.name))
                local gram = GramMatrix():float()
                if params.gpu >= 0 then
                    if params.backend ~= 'clnn' then
                        gram = gram:cuda()
                    else
                        gram = gram:cl()
                    end
                end
                local target = nil
                for i = 1, #style_images_caffe do
                    local target_features = net:forward(style_images_caffe[i]):clone()
                    local target_i = gram:forward(target_features):clone()
                    target_i:div(target_features:nElement())
                    target_i:mul(style_blend_weights[i])
                    if i == 1 then
                        target = target_i
                    else
                        target:add(target_i)
                    end
                end
                local norm = params.normalize_gradients
                local loss_module = nn.StyleLoss(params.style_weight, target, norm):float()
                if params.gpu >= 0 then
                    if params.backend ~= 'clnn' then
                        loss_module:cuda()
                    else
                        loss_module:cl()
                    end
                end
                net:add(loss_module)
                table.insert(style_losses, loss_module)
                next_style_idx = next_style_idx + 1
            end
        end
    end

    -- We don't need the base CNN anymore, so clean it up to save memory.
    cnn = nil
    for i = 1, #net.modules do
        local module = net.modules[i]
        if torch.type(module) == 'nn.SpatialConvolutionMM' then
            -- remove these, not used, but uses gpu memory
            module.gradWeight = nil
            module.gradBias = nil
        end
    end
    --  collectgarbage()

    -- Initialize the image
    if params.seed >= 0 then
        torch.manualSeed(params.seed)
    end
    local img = nil
    if params.init == 'random' then
        img = torch.randn(content_image:size()):float():mul(0.001)
    elseif params.init == 'image' then
        img = content_image_caffe:clone():float()
    else
        error('Invalid init type')
    end
    if params.gpu >= 0 then
        if params.backend ~= 'clnn' then
            img = img:cuda()
        else
            img = img:cl()
        end
    end

    -- Run it through the network once to get the proper size for the gradient
    -- All the gradients will come from the extra loss modules, so we just pass
    -- zeros into the top of the net on the backward pass.
    local y = net:forward(img)
    local dy = img.new(#y):zero()

    -- Declaring this here lets us access it in maybe_print
    local optim_state = nil
    if params.optimizer == 'lbfgs' then
        optim_state = {
            maxIter = params.num_iterations,
            verbose = true,
        }
    elseif params.optimizer == 'adam' then
        optim_state = {
            learningRate = params.learning_rate,
        }
    else
        error(string.format('Unrecognized optimizer "%s"', params.optimizer))
        updateProgress(string.format('Unrecognized optimizer "%s"', params.optimizer))
    end

    local function maybe_print(t, loss)
        local verbose = (params.print_iter > 0 and t % params.print_iter == 0)
        if verbose then
            updateProgress(string.format('Iteration %d / %d', t, params.num_iterations))
            for i, loss_module in ipairs(content_losses) do
                updateProgress(string.format('  Content %d loss: %f', i, loss_module.loss))
            end
            for i, loss_module in ipairs(style_losses) do
                updateProgress(string.format('  Style %d loss: %f', i, loss_module.loss))
            end
            updateProgress(string.format('  Total loss: %f', loss))
        end
    end

    local function maybe_save(t)
        local should_save = params.save_iter > 0 and t % params.save_iter == 0
        should_save = should_save or t == params.num_iterations
        if should_save then
            local disp = deprocess(img:double())
            disp = image.minmax { tensor = disp, min = 0, max = 1 }
            local filename = build_filename(params.output_image, t)
            local isFinal = false;
            if t == params.num_iterations then
                isFinal = true;
                filename = params.output_image
            end
            updateProgress("Saving image")
            image.save(filename, disp)
            updateProgress(string.format("Image saved in %s ", filename))
            onImageSaved(filename)
        end
    end

    -- Function to evaluate loss and gradient. We run the net forward and
    -- backward to get the gradient, and sum up losses from the loss modules.
    -- optim.lbfgs internally handles iteration and calls this fucntion many
    -- times, so we manually count the number of iterations to handle printing
    -- and saving intermediate results.
    local num_calls = 0
    local function feval(x)
        num_calls = num_calls + 1
        net:forward(x)
        local grad = net:updateGradInput(x, dy)
        local loss = 0
        print(ipairs(content_losses))
        for _, mod in ipairs(content_losses) do
            loss = loss + mod.loss
        end
        for _, mod in ipairs(style_losses) do
            loss = loss + mod.loss
        end
        maybe_print(num_calls, loss)
        maybe_save(num_calls)
        -- optim.lbfgs expects a vector for gradients
        return loss, grad:view(grad:nElement())
    end

    -- Run optimization.
    if params.optimizer == 'lbfgs' then
        updateProgress('Running optimization with L-BFGS')
        local x, losses = optim.lbfgs(feval, img, optim_state)
        updateProgress("Done")
    elseif params.optimizer == 'adam' then
        updateProgress('Running optimization with ADAM')
        for t = 1, params.num_iterations do
            updateProgress(string.format("Doing Iteration %i of %s ...", t, params.num_iterations))
            --            updateIteration(t, params.num_iterations)
            local x, losses = optim.adam(feval, img, optim_state)
        end
        updateProgress("Done")
        onCompleted()
    end
end


function build_filename(output_image, iteration)
    local ext = paths.extname(output_image)
    local basename = paths.basename(output_image, ext)
    local directory = paths.dirname(output_image)
    return string.format('%s/%s_%d.%s', directory, basename, iteration, ext)
end


-- Preprocess an image before passing it to a Caffe model.
-- We need to rescale from [0, 1] to [0, 255], convert from RGB to BGR,
-- and subtract the mean pixel.
function preprocess(img)
    local mean_pixel = torch.DoubleTensor({ 103.939, 116.779, 123.68 })
    local perm = torch.LongTensor { 3, 2, 1 }
    img = img:index(1, perm):mul(256.0)
    mean_pixel = mean_pixel:view(3, 1, 1):expandAs(img)
    img:add(-1, mean_pixel)
    return img
end


-- Undo the above preprocessing.
function deprocess(img)
    local mean_pixel = torch.DoubleTensor({ 103.939, 116.779, 123.68 })
    mean_pixel = mean_pixel:view(3, 1, 1):expandAs(img)
    img = img + mean_pixel
    local perm = torch.LongTensor { 3, 2, 1 }
    img = img:index(1, perm):div(256.0)
    return img
end


-- Define an nn Module to compute content loss in-place
local ContentLoss, parent = torch.class('nn.ContentLoss', 'nn.Module')

function ContentLoss:__init(strength, target, normalize)
    parent.__init(self)
    self.strength = strength
    self.target = target
    self.normalize = normalize or false
    self.loss = 0
    self.crit = nn.MSECriterion()
end

function ContentLoss:updateOutput(input)
    if input:nElement() == self.target:nElement() then
        self.loss = self.crit:forward(input, self.target) * self.strength
    else
        print('WARNING: Skipping content loss')
    end
    self.output = input
    return self.output
end

function ContentLoss:updateGradInput(input, gradOutput)
    if input:nElement() == self.target:nElement() then
        self.gradInput = self.crit:backward(input, self.target)
    end
    if self.normalize then
        self.gradInput:div(torch.norm(self.gradInput, 1) + 1e-8)
    end
    self.gradInput:mul(self.strength)
    self.gradInput:add(gradOutput)
    return self.gradInput
end

-- Returns a network that computes the CxC Gram matrix from inputs
-- of size C x H x W
function GramMatrix()
    local net = nn.Sequential()
    net:add(nn.View(-1):setNumInputDims(2))
    local concat = nn.ConcatTable()
    concat:add(nn.Identity())
    concat:add(nn.Identity())
    net:add(concat)
    net:add(nn.MM(false, true))
    return net
end


-- Define an nn Module to compute style loss in-place
local StyleLoss, parent = torch.class('nn.StyleLoss', 'nn.Module')

function StyleLoss:__init(strength, target, normalize)
    parent.__init(self)
    self.normalize = normalize or false
    self.strength = strength
    self.target = target
    self.loss = 0

    self.gram = GramMatrix()
    self.G = nil
    self.crit = nn.MSECriterion()
end

function StyleLoss:updateOutput(input)
    self.G = self.gram:forward(input)
    self.G:div(input:nElement())
    self.loss = self.crit:forward(self.G, self.target)
    self.loss = self.loss * self.strength
    self.output = input
    return self.output
end

function StyleLoss:updateGradInput(input, gradOutput)
    local dG = self.crit:backward(self.G, self.target)
    dG:div(input:nElement())
    self.gradInput = self.gram:backward(input, dG)
    if self.normalize then
        self.gradInput:div(torch.norm(self.gradInput, 1) + 1e-8)
    end
    self.gradInput:mul(self.strength)
    self.gradInput:add(gradOutput)
    return self.gradInput
end


local TVLoss, parent = torch.class('nn.TVLoss', 'nn.Module')

function TVLoss:__init(strength)
    parent.__init(self)
    self.strength = strength
    self.x_diff = torch.Tensor()
    self.y_diff = torch.Tensor()
end

function TVLoss:updateOutput(input)
    self.output = input
    return self.output
end

-- TV loss backward pass inspired by kaishengtai/neuralart
function TVLoss:updateGradInput(input, gradOutput)
    self.gradInput:resizeAs(input):zero()
    local C, H, W = input:size(1), input:size(2), input:size(3)
    self.x_diff:resize(3, H - 1, W - 1)
    self.y_diff:resize(3, H - 1, W - 1)
    self.x_diff:copy(input[{ {}, { 1, -2 }, { 1, -2 } }])
    self.x_diff:add(-1, input[{ {}, { 1, -2 }, { 2, -1 } }])
    self.y_diff:copy(input[{ {}, { 1, -2 }, { 1, -2 } }])
    self.y_diff:add(-1, input[{ {}, { 2, -1 }, { 1, -2 } }])
    self.gradInput[{ {}, { 1, -2 }, { 1, -2 } }]:add(self.x_diff):add(self.y_diff)
    self.gradInput[{ {}, { 1, -2 }, { 2, -1 } }]:add(-1, self.x_diff)
    self.gradInput[{ {}, { 2, -1 }, { 1, -2 } }]:add(-1, self.y_diff)
    self.gradInput:mul(self.strength)
    self.gradInput:add(gradOutput)
    return self.gradInput
end

