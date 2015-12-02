#!/usr/bin/python

import numpy as np
import matplotlib
#matplotlib.use('GTK')
import matplotlib.pyplot as plt

import sys
import os
import caffe
import lmdb
from caffe.proto import caffe_pb2

plt.rcParams['figure.figsize'] = (10, 10)
plt.rcParams['image.interpolation'] = 'nearest'
plt.rcParams['image.cmap'] = 'gray'


# take an array of shape (n, height, width) or (n, height, width, channels)
# and visualize each (height, width) thing in a grid of size approx. sqrt(n) by sqrt(n)
def vis_square(data, padsize=1, padval=0):
    data -= data.min()
    data /= data.max()

    # force the number of filters to be square
    n = int(np.ceil(np.sqrt(data.shape[0])))
    padding = ((0, n ** 2 - data.shape[0]), (0, padsize), (0, padsize)) + ((0, 0),) * (data.ndim - 3)
    data = np.pad(data, padding, mode='constant', constant_values=(padval, padval))

    # tile the filters into an image
    data = data.reshape((n, n) + data.shape[1:]).transpose((0, 2, 1, 3) + tuple(range(4, data.ndim + 1)))
    data = data.reshape((n * data.shape[1], n * data.shape[3]) + data.shape[4:])
    print "plotting data"
    plt.imshow(data)
    plt.show()




caffe_root = '../../tools/caffe/'
models = {}
models['caffenet'] = {  'pretrain': caffe_root + 'models/bvlc_reference_caffenet/bvlc_reference_caffenet.caffemodel', 
                        'network': caffe_root + 'models/bvlc_reference_caffenet/deploy.prototxt',
                        'mean': caffe_root + 'python/caffe/imagenet/ilsvrc_2012_mean.npy' 
                        }

#models['googlenet'] = {  'pretrain': caffe_root + 'models/bvlc_googlenet/bvlc_googlenet.caffemodel', 
#                        'network': caffe_root + 'models/bvlc_googlenet/deploy.prototxt',
#                        'mean': caffe_root + 'python/caffe/imagenet/ilsvrc_2012_mean.npy' #FIXME: is this the right file?
#                        }

val_lmdb = caffe_root + 'examples/imagenet/ilsvrc12_val_lmdb'

lmdb_env = lmdb.open(val_lmdb)
lmdb_txn = lmdb_env.begin()
lmdb_cursor = lmdb_txn.cursor()
datum = caffe_pb2.Datum()

caffe.set_mode_gpu()
#shared_ptr<Net<Dtype> > Net_Init_Load(string param_file, string pretrained_param_file, int phase) 
for modelname, modelpaths in models.iteritems():
    net = caffe.Net(modelpaths['network'], modelpaths['pretrain'], caffe.TEST)

    #transformer = caffe.io.Transformer({'data': net.blobs['data'].data.shape})
    #transformer.set_transpose('data', (2,0,1)) #required
    img_mean = np.load(modelpaths['mean']).mean(1).mean(1) # mean pixel
    #transformer.set_mean('data', m)
    #transformer.set_raw_scale('data', 255)  # the reference model operates on images in [0,255] range instead of [0,1]. This is because python represents images in [0,1]
    #transformer.set_channel_swap('data', (2,1,0))  # the reference model has channels in BGR order instead of RGB
    #b = net.blobs['data']
    #print b.num, b.channels, b.height, b.width, b.count
    #print type(net.blobs['data'])

    #ml: Don't think we need to reshape for batch size 50 here. Just use the default 10
    #net.blobs['data'].reshape(50,3,227,227) #reshape is a specialized function here
    #b = net.blobs['data']
    #print b.num, b.channels, b.height, b.width, b.count
    

    total = 0
    correct = 0
    sparsity_dict = {}

    #3x256x256 images represented using [0,255] in **BGR** order
    for img_name, value in lmdb_cursor:
        total += 1
        
        datum.ParseFromString(value)
        label = datum.label
        data = caffe.io.datum_to_array(datum)
        print "db datum:"
        print img_name, label
        #print data.shape, type(data)
        #print data 
        #plt.imshow(data.transpose([1,2,0])) #FIXME this is showing BGR
        #plt.show()

        #preprocess the images manually
        # 1) convert to float. Python wrapper always uses float types
        caffe_in = data.astype(np.float32, copy=False)
        # 2) take the center crop
        cropped_size = net.blobs['data'].data.shape[3]
        bound_lower = (data.shape[1] - cropped_size) / 2
        caffe_in = caffe_in[:, bound_lower:bound_lower+cropped_size, bound_lower:bound_lower+cropped_size]
        # 3) subtract average along the channel axis
        caffe_in -= img_mean[:, np.newaxis, np.newaxis]
        #print "caffe_in"
        #print caffe_in.shape
        #print caffe_in

        net.blobs['data'].data[...] = caffe_in 

        out = net.forward()
        pred = out['prob'][0].argmax()

        print("Predicted class is #{}.".format(pred))

        if pred == label:
            correct += 1
        
        print "running accuracy: ", correct / float(total)

        print "running sparsities: "
        for k, v in net.blobs.iteritems():
            feat = v.data[0,:]
            sparsity = (feat.size - np.count_nonzero(feat)) / float(feat.size)
            sparsity_dict[k] = sparsity_dict.get(k, 0.0) + sparsity
            #print k 
            print k, feat.shape
            print "%0.2f " %  (sparsity_dict[k] / float(total))
            #print "almost zeros", np.sum(feat<1e-5) / float( feat.size )
            #print feat
            #vis_square(feat, padval=1)
        print "---"







    #img = caffe.io.load_image(caffe_root + 'examples/images/fish-bike.jpg')
    #img = caffe.io.load_image('/home/mingliu/imagenet/val/ILSVRC2012_val_00044094.JPEG')
    #print "manual image:"
    #print img.shape
    #print img
#        d = transformer.preprocess('data', data)
#        print d.shape
#        print d
#        net.blobs['data'].data[...] = d
#
#        out = net.forward()
#
#        print("Predicted class is #{}.".format(out['prob'][0].argmax()))
#
#        plt.imshow(transformer.deprocess('data', net.blobs['data'].data[0]))


    # load labels
    imagenet_labels_filename = caffe_root + 'data/ilsvrc12/synset_words.txt'
    labels = np.loadtxt(imagenet_labels_filename, str, delimiter='\t')

# sort top k predictions from softmax output
    top_k = net.blobs['prob'].data[0].flatten().argsort()[-1:-6:-1]
    print labels[top_k]

    for k, v in net.blobs.iteritems():
        print k
        feat = v.data[0,:]
        print feat.shape
        print (feat.size - np.count_nonzero(feat)) / float(feat.size)

#feat = net.blobs['pool2'].data[0, :]
#print feat.shape
#print (feat.size - np.count_nonzero(feat)) / float(feat.size)
#vis_square(feat, padval=1)
    plt.show()






