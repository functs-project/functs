from nvidia/cuda:11.6.1-devel-ubuntu20.04
WORKDIR /root
SHELL ["/bin/bash", "--login", "-c"]
RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive TZ=Asia/Shanghai apt-get -y install tzdata
RUN apt-get install -y wget git cmake 
RUN wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh &&  bash Miniconda3-latest-Linux-x86_64.sh -b
# RUN . ~/miniconda3/etc/profile.d/conda.sh && conda init
ENV PATH="/root/miniconda3/bin:${PATH}"
RUN source /root/miniconda3/etc/profile.d/conda.sh && conda activate
RUN pip install torch==2.1.0 torchvision==0.16.1
RUN pip install numpy pytest
RUN git clone https://github.com/functs-project/functs.git --recursive

# COPY functs/benchmark/ai_model/yolov3/yolov3_feat.pt /root/functs/functs/benchmark/ai_model/yolov3/yolov3_feat.pt
# COPY functs/benchmark/ai_model/ssd/ssd_feat.pt /root/functs/functs/benchmark/ai_model/ssd/ssd_feat.pt
# COPY functs/benchmark/ai_model/fcos/fcos_feat.pt /root/functs/functs/benchmark/ai_model/fcos/fcos_feat.pt
# COPY functs/benchmark/ai_model/yolact/yolact_feat.pt /root/functs/functs/benchmark/ai_model/yolact/yolact_feat.pt



