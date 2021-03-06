/**
 * Appcelerator Titanium Mobile
 * Copyright (c) 2009-2010 by Appcelerator, Inc. All Rights Reserved.
 * Licensed under the terms of the Apache Public License
 * Please see the LICENSE included with this distribution for details.
 */

#import "ImageLoader.h"
#import "OperationQueue.h"
#import "TiUtils.h"
#import "ASIHTTPRequest.h"
#import "TiApp.h"
#import "UIImage+Resize.h"

#ifdef VERBOSE
#import <mach/mach.h>
#endif



@interface ImageCacheEntry : NSObject
{
	UIImage * fullImage;
	UIImage * stretchableImage;
	UIImage * recentlyResizedImage;
    TiDimension leftCap;
    TiDimension topCap;
    BOOL recapStretchableImage;
}

@property(nonatomic,readwrite,retain) UIImage * fullImage;
@property(nonatomic,readwrite,retain) UIImage * recentlyResizedImage;
@property(nonatomic,readwrite) TiDimension leftCap;
@property(nonatomic,readwrite) TiDimension topCap;
-(UIImage *)imageForSize:(CGSize)imageSize;
-(UIImage *)stretchableImage;

-(BOOL)purgable;

@end

@implementation ImageCacheEntry
@synthesize fullImage, recentlyResizedImage, leftCap, topCap;

-(UIImage *)imageForSize:(CGSize)imageSize scalingStyle:(TiImageScalingStyle)scalingStyle
{
	if (scalingStyle == TiImageScalingStretch)
	{
		return [self stretchableImage];
	}

	CGSize fullImageSize = [fullImage size];

	if (scalingStyle != TiImageScalingNonProportional)
	{
		BOOL validScale = NO;
		CGFloat scale = 1.0;
		
		if (imageSize.height > 1.0)
		{
			scale = imageSize.height/fullImageSize.height;
			validScale = YES;
		}
		if (imageSize.width > 1.0)
		{
			CGFloat widthScale = imageSize.width/fullImageSize.width;
			if (!validScale || (widthScale<scale))
			{
				scale = widthScale;
				validScale = YES;
			}
		}
		
		if (validScale && ((scalingStyle != TiImageScalingThumbnail) || (scale < 1.0)))
		{
			imageSize = CGSizeMake(ceilf(scale*fullImageSize.width),
					ceilf(scale*fullImageSize.height));
		}
		else
		{
			imageSize = fullImageSize;
		}
	}

	if (CGSizeEqualToSize(imageSize, fullImageSize))
	{
		return fullImage;
	}
	
	if (CGSizeEqualToSize(imageSize, [recentlyResizedImage size]))
	{
		return recentlyResizedImage;
	}

//TODO: Tweak quality depending on how large the result will be.
	CGInterpolationQuality quality = kCGInterpolationDefault;

	[self setRecentlyResizedImage:[UIImageResize
			resizedImage:imageSize
			interpolationQuality:quality
			image:fullImage]];
	return recentlyResizedImage;
}

-(void)setLeftCap:(TiDimension)cap
{
    if (!TiDimensionEqual(leftCap, cap)) {
        leftCap = cap;
        recapStretchableImage = YES;
    }
}

-(void)setTopCap:(TiDimension)cap
{
    if (!TiDimensionEqual(topCap, cap)) {
        topCap = cap;
        recapStretchableImage = YES;
    }
}

-(UIImage *)stretchableImage
{
    if (stretchableImage == nil || recapStretchableImage) {
        [stretchableImage release];
        
        CGSize imageSize = [fullImage size];
        
        NSInteger left = (TiDimensionIsAuto(leftCap) || TiDimensionIsUndefined(leftCap) || leftCap.value == 0) ?
                                imageSize.width/2  : 
                                TiDimensionCalculateValue(leftCap, imageSize.width);
        NSInteger top = (TiDimensionIsAuto(topCap) || TiDimensionIsUndefined(topCap) || topCap.value == 0) ? 
                                imageSize.height/2  : 
                                TiDimensionCalculateValue(topCap, imageSize.height);
        
        stretchableImage = [[fullImage stretchableImageWithLeftCapWidth:left
                                                           topCapHeight:top] retain];
        recapStretchableImage = NO;
    }
	return stretchableImage;
}

-(UIImage *)imageForSize:(CGSize)imageSize
{
	return [self imageForSize:imageSize scalingStyle:TiImageScalingDefault];
}

-(BOOL)purgable
{
	BOOL canPurge = YES;
	if ([recentlyResizedImage retainCount]<2)
	{
		RELEASE_TO_NIL(recentlyResizedImage)
	}
	else
	{
		canPurge = NO;
	}

	if ([stretchableImage retainCount]<2)
	{
		RELEASE_TO_NIL(stretchableImage)
	}
	else
	{
		canPurge = NO;
	}

	if (canPurge && [fullImage retainCount]<2)
	{
		RELEASE_TO_NIL(fullImage);
		return YES;
	}
	return NO;
}

- (void) dealloc
{
	RELEASE_TO_NIL(recentlyResizedImage);
	RELEASE_TO_NIL(stretchableImage);
	RELEASE_TO_NIL(fullImage);
	[super dealloc];
}


@end









ImageLoader *sharedLoader = nil;

@implementation ImageLoaderRequest

@synthesize completed, delegate, imageSize;

DEFINE_EXCEPTIONS

-(void)dealloc
{
	RELEASE_TO_NIL(request);
	RELEASE_TO_NIL(delegate);
	RELEASE_TO_NIL(userInfo);
	RELEASE_TO_NIL(url);
	[super dealloc];
}

-(id)initWithCallback:(NSObject<ImageLoaderDelegate>*)target_ userInfo:(id)userInfo_ url:(NSURL*)url_
{
	if (self = [super init])
	{
		delegate = [target_ retain];
		userInfo = [userInfo_ retain];
		url = [url_ retain];
	}
	return self;
}

-(void)setRequest:(ASIHTTPRequest*)request_
{
	request = [request_ retain];
}

-(void)cancel
{
	cancelled = YES;
	[request cancel];
	RELEASE_TO_NIL(request);
}

-(BOOL)cancelled
{
	return cancelled;
}

-(id)userInfo
{
	return userInfo;
}

-(NSURL*)url
{
	return url;
}

@end


@implementation ImageLoader

-(id)init
{
	if (self = [super init])
	{
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(didReceiveMemoryWarning:)
													 name:UIApplicationDidReceiveMemoryWarningNotification  
												   object:nil]; 
		lock = [[NSRecursiveLock alloc] init];
	}
	return self;
}

-(void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self
													name:UIApplicationDidReceiveMemoryWarningNotification  
												  object:nil];  
	RELEASE_TO_NIL(cache);
	RELEASE_TO_NIL(queue);
	RELEASE_TO_NIL(timeout);
	RELEASE_TO_NIL(lock);
	[super dealloc];
}

-(void)didReceiveMemoryWarning:(id)sender
{
	NSString * doomedKey;

#ifdef VERBOSE
	int cacheCount = [cache count];
	vm_statistics_data_t vmStats;
	mach_msg_type_number_t infoCount = HOST_VM_INFO_COUNT;
	kern_return_t kernReturn = host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vmStats, &infoCount);
	NSLog(@"[INFO] %d pages free before clearing image cache.",vmStats.free_count);
#endif


	do
	{
		doomedKey = nil;
		for (NSString * thisKey in cache)
		{
			ImageCacheEntry * thisValue = [cache objectForKey:thisKey];
			if ([thisValue purgable])
			{
				doomedKey = thisKey;
				break;
			}
		}
		if (doomedKey != nil)
		{
			VerboseLog(@"[INFO] Due to memory conditions, releasing cached image: %@",doomedKey);
			[cache removeObjectForKey:doomedKey];
		}
	} while (doomedKey != nil);
#ifdef VERBOSE
	kernReturn = host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vmStats, &infoCount);
	NSLog(@"[INFO] %d of %d images remain in cache, %d pages now free.",[cache count],cacheCount,vmStats.free_count);
#endif


}

+(ImageLoader*)sharedLoader
{
	if (sharedLoader==nil)
	{
		sharedLoader = [[ImageLoader alloc] init];
	}
	return sharedLoader;
}

-(ImageCacheEntry *)setImage:(UIImage *)image forKey:(NSString *)urlString cache:(BOOL)doCache
{
	if (image==nil)
	{
		return nil;
	}
	if (cache==nil)
	{
		cache = [[NSMutableDictionary alloc] init];
	}
	ImageCacheEntry * newEntry = [[[ImageCacheEntry alloc] init] autorelease];
	[newEntry setFullImage:image];
	
	if (doCache)
	{
		VerboseLog(@"[DEBUG] Caching image %@: %@",urlString,image);
		[cache setObject:newEntry forKey:urlString];
	}
	return newEntry;
}

-(ImageCacheEntry *)setImage:(UIImage *)image forKey:(NSString *)urlString
{
	return [self setImage:image forKey:urlString cache:YES];
}

-(ImageCacheEntry *)entryForKey:(NSURL *)url
{
	if (url == nil)
	{
		return nil;
	}

	NSString * urlString = [url absoluteString];
	ImageCacheEntry * result = [cache objectForKey:urlString];
	
	if ((result == nil) && [url isFileURL])
	{
		//Well, let's make it for them!
		UIImage * resultImage = [UIImage imageWithContentsOfFile:[url path]];
		result = [self setImage:resultImage forKey:urlString];
	}
	
	return result;
}



-(id)cache:(UIImage*)image forURL:(NSURL*)url size:(CGSize)imageSize
{
	return [[self setImage:image forKey:[url absoluteString]] imageForSize:imageSize];
}

-(id)cache:(UIImage*)image forURL:(NSURL*)url
{
	return [self cache:image forURL:url size:CGSizeZero];
}


-(id)loadRemote:(NSURL*)url
{
	if (url==nil) return nil;
	UIImage *image = [[self entryForKey:url] imageForSize:CGSizeZero];
	if (image!=nil)
	{
		return image;
	}
	
	ASIHTTPRequest *req = [ASIHTTPRequest requestWithURL:url];
	[req addRequestHeader:@"User-Agent" value:[[TiApp app] userAgent]];
	[[TiApp app] startNetwork];
	[req start];
	[[TiApp app] stopNetwork];
	
	if (req!=nil && [req error]==nil)
	{
		UIImage * resultImage = [UIImage imageWithData:[req responseData]];
		return [[self setImage:resultImage forKey:[url absoluteString]] imageForSize:CGSizeZero];
	}
	
	return nil;
}

-(UIImage *)loadImmediateImage:(NSURL *)url
{
	return [self loadImmediateImage:url withSize:CGSizeZero];
}


-(UIImage *)loadImmediateImage:(NSURL *)url withSize:(CGSize)imageSize;
{
	return [[self entryForKey:url] imageForSize:imageSize];
}

-(UIImage *)loadImmediateStretchableImage:(NSURL *)url
{
    return [self loadImmediateStretchableImage:url withLeftCap:TiDimensionAuto topCap:TiDimensionAuto];
}

-(UIImage *)loadImmediateStretchableImage:(NSURL *)url withLeftCap:(TiDimension)left topCap:(TiDimension)top
{
    ImageCacheEntry* image = [self entryForKey:url];
    image.leftCap = left;
    image.topCap = top;
	return [image stretchableImage];    
}

-(void)notifyImageCompleted:(NSArray*)args
{
	if ([args count]==2)
	{
		ImageLoaderRequest *request = [args objectAtIndex:0];
		UIImage *image = [args objectAtIndex:1];
		[[request delegate] imageLoadSuccess:request image:image];
	}
}

-(void)doImageLoader:(ImageLoaderRequest*)request
{
	NSURL *url = [request url];
	
	UIImage *image = [[self entryForKey:url] imageForSize:[request imageSize]];
	if (image!=nil)
	{
		[self performSelectorOnMainThread:@selector(notifyImageCompleted:) withObject:[NSArray arrayWithObjects:request,image,nil] waitUntilDone:NO modes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
		return;
	}
	
	// we don't have it local or in the cache so we need to fetch it remotely
	if (queue == nil)
	{
		queue = [[ASINetworkQueue alloc] init];
		[queue setMaxConcurrentOperationCount:4];
		[queue setShouldCancelAllRequestsOnFailure:NO];
		[queue setDelegate:self];
		[queue setRequestDidFailSelector:@selector(queueRequestDidFail:)];
		[queue setRequestDidFinishSelector:@selector(queueRequestDidFinish:)];
		[queue go];
	}
	
	NSDictionary *dict = [NSDictionary dictionaryWithObject:request forKey:@"request"];
	ASIHTTPRequest *req = [ASIHTTPRequest requestWithURL:url];
	[req setUserInfo:dict];
	[req setRequestMethod:@"GET"];
	[req addRequestHeader:@"User-Agent" value:[[TiApp app] userAgent]];
	[req setTimeOutSeconds:20];
	[request setRequest:req];
	
	[[TiApp app] startNetwork];
	
	[queue addOperation:req];
}

-(ImageLoaderRequest*)loadImage:(NSURL*)url delegate:(NSObject<ImageLoaderDelegate>*)delegate userInfo:(NSDictionary*)userInfo
{
	ImageLoaderRequest *request = [[[ImageLoaderRequest alloc] initWithCallback:delegate userInfo:userInfo url:url] autorelease];
	
	// if have a queue and it's suspend, just throw our request
	// in the timeout queue until we're resumed
	if (queue!=nil && [queue isSuspended])
	{
		[lock lock];
		if (timeout==nil)
		{
			timeout = [[NSMutableArray alloc] initWithCapacity:4];
		}
		[timeout addObject:request];
		[lock unlock];
		return request;
	}
	
	[self doImageLoader:request];
	
	return request;
}

-(void)suspend
{
	[lock lock];
	if (queue!=nil)
	{
		[queue setSuspended:YES];
	}
	[lock unlock];
}

-(void)resume
{
	[lock lock];
	
	if (queue!=nil)
	{
		[queue setSuspended:NO];
	}
	
	if (timeout!=nil)
	{
		for (ImageLoaderRequest *request in timeout)
		{
			if ([request cancelled])
			{
				if ([[request delegate] respondsToSelector:@selector(imageLoadCancelled:)])
				{
					[[request delegate] performSelector:@selector(imageLoadCancelled:) withObject:request];
				}
			}
			else
			{
				[self doImageLoader:request];
			}
		}
		[timeout removeAllObjects];
	}
	[lock unlock];
}


#pragma mark Delegates


-(void)queueRequestDidFinish:(ASIHTTPRequest*)request
{
	ENSURE_UI_THREAD_1_ARG(request);

	// hold while we're working with it (release below)
	[request retain];
	
	[[TiApp app] stopNetwork];
	ImageLoaderRequest *req = [[request userInfo] objectForKey:@"request"];
	if ([req cancelled]==NO)
	{
		NSData *data = [request responseData];
		if (data == nil || [data length]==0)
		{
			NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
			[errorDetail setValue:@"Response returned nil" forKey:NSLocalizedDescriptionKey];
			NSError *error = [NSError errorWithDomain:@"com.appcelerator.titanium.imageloader" code:1 userInfo:errorDetail];
			[[req delegate] imageLoadFailed:req error:error];
			[request release];
			return;
		}
		
		// we want to be able to cache remote images so we need to
		// honor cache control parameters - however, we're only caching
		// for this session and not on disk so we ignore (potentially at a determinent?)
		// the actual max-age setting for now.
		NSString *cacheControl = [[request responseHeaders] objectForKey:@"Cache-Control"];
		BOOL cacheable = YES;
		if (cacheControl!=nil)
		{
			// check to see if we're cacheable or not
			NSRange range = [cacheControl rangeOfString:@"max-age=0"];
			if (range.location!=NSNotFound)
			{
				cacheable = NO;
			}
			else 
			{
				range = [cacheControl rangeOfString:@"no-cache"];
				if (range.location!=NSNotFound)
				{
					cacheable = NO;
				}
			}
		}
		
		UIImage *image = [UIImage imageWithData:data];
		
		if (cacheable)
		{
			[self cache:image forURL:[request url]];
		}
		
		[self notifyImageCompleted:[NSArray arrayWithObjects:req,image,nil]];
	}
	else
	{
		if ([[req delegate] respondsToSelector:@selector(imageLoadCancelled:)])
		{
			[[req delegate] performSelector:@selector(imageLoadCancelled:) withObject:req];
		}
	}
	[request release];
}

-(void)queueRequestDidFail:(ASIHTTPRequest*)request
{
	[[TiApp app] stopNetwork];
	ImageLoaderRequest *req = [[request userInfo] objectForKey:@"request"];
	NSError *error = [request error];
	if ([error code] == ASIRequestCancelledErrorType && [error domain] == NetworkRequestErrorDomain)
	{
		if ([[req delegate] respondsToSelector:@selector(imageLoadCancelled:)])
		{
			[[req delegate] performSelector:@selector(imageLoadCancelled:) withObject:req];
		}
	}
	else 
	{
		[[req delegate] imageLoadFailed:req error:[request error]];
	}
}

@end
