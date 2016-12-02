#!/bin/bash
set -x

ceph mon remove $(hostname -s)
