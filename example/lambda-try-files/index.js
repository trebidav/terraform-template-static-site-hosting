/* eslint-disable */
'use strict';

const AWS = require('aws-sdk');

const BUCKET_NAME = '%S3_BUCKET%';
const S3_REGION = '%AWS_REGION%';

const pointsToFile = (uri) => /\/[^/]+\.[^/]+$/.test(uri);
const hasTrailingSlash = (uri) => /^.+\/$/.test(uri);

const matchRoutes = (routes, path) => {
    for (const routeKey in routes) {
        const route = routes[routeKey];

        if (!route.path) {
            continue;
        }

        const regexStr = `^${route.path
            .replace(/\//g, '\\/')
            .replace(/:[^\\/]+/g, '[^/]+')}(\\?.+){0,1}\$`;
        const regex = new RegExp(regexStr);

        if (regex.test(path)) {
            return true;
        }
    }

    return false;
};

const s3Connect = (options = {}) =>
    new AWS.S3({
        ...options,
        region: S3_REGION,
    });

const retrieveS3TextFile = async (s3, filePath) => {
    let data;

    try {
        data = await s3
            .getObject({
                Bucket: BUCKET_NAME,
                Key: filePath,
            })
            .promise();

        if (data) {
            return data.Body.toString('utf-8');
        }
    } catch (err) {
        console.error(err);
    }

    return undefined;
};

const retrieveRoutes = async (s3) => {
    const file = await retrieveS3TextFile(s3, 'routes.json');

    if (file) {
        return JSON.parse(file);
    }

    return undefined;
};

exports.handler = async (event, context, callback) => {
    // Extract the request from the CloudFront event that is sent to Lambda@Edge
    const request = event.Records[0].cf.request;
    const path = request.uri === '/index.html' ? '/' : request.uri;

    if (request.method !== 'GET' || pointsToFile(path) || hasTrailingSlash(path)) {
        callback(null, request);
        return;
    }

    const s3 = s3Connect();

    /**
     * Route matching
     */
    const routes = await retrieveRoutes(s3);
    if (routes && matchRoutes(routes, path)) {
        request.uri = '/index.html';

        /**
         * SSR rewrite
         */
        const ssrFile = `ssr/${path === '/' ? 'homepage' : path.split('/').join('')}.html`;
        console.log('ssrFile', ssrFile);
        const ssrFileContent = await retrieveS3TextFile(s3, ssrFile);
        if (ssrFileContent) {
            request.uri = `/${ssrFile}`;
        }
    }

    callback(null, request);
};

