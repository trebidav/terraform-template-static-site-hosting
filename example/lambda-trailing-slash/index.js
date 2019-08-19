'use strict';

const hasTrailingSlash = (uri) => /^.+\/$/.test(uri);

exports.handler = (event, context, callback) => {
    const response = event.Records[0].cf.response;
    const request = event.Records[0].cf.request;

    if (hasTrailingSlash(request.uri)) {
        const redirect_path = `${request.uri.replace(/\/+$/, '')}${!!request.querystring ? `?${request.querystring}` : ''}`;
        console.log(redirect_path)

        response.status = 301;
        response.statusDescription = 'Moved Permanently';

        /* Drop the body, as it is not required for redirects */
        response.body = '';
        response.headers['location'] = [{ key: 'Location', value: redirect_path }];
    }

    callback(null, response);
};

