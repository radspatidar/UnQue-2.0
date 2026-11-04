
export const notFound = (req, res, next) => {
    const error = new Error(`Not Found - ${req.originalUrl}`);
    res.status(404);
    next(error);
};

export const errorMiddleware = (err, req, res, next) => {
    const statusCode =
        Number.isInteger(err.code) &&
        err.code >= 400 &&
        err.code <= 599
            ? err.code
            : (res.statusCode >= 400 ? res.statusCode : 500);

    res.status(statusCode).json({
        message: err.message || "Internal Server Error"
    });
};